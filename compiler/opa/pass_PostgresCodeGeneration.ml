(*
    Copyright © 2011-2013 MLstate

    This file is part of Opa.

    Opa is free software: you can redistribute it and/or modify it under the
    terms of the GNU Affero General Public License, version 3, as published by
    the Free Software Foundation.

    Opa is distributed in the hope that it will be useful, but WITHOUT ANY
    WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
    FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for
    more details.

    You should have received a copy of the GNU Affero General Public License
    along with Opa. If not, see <http://www.gnu.org/licenses/>.
*)

module Format = BaseFormat
module List = BaseList

module Q = QmlAst
module QD = Q.Db
module S = QmlDbGen.Schema

module C = QmlAstCons.TypedExpr

module Api =
struct

  module Db = Opacapi.DbPostgres

  module Option = Opacapi.Option

  module List = Opacapi.List

  module DbSet = Opacapi.DbSet

  let serialize = Opacapi.OpaSerialize.serialize

  module Types = Opacapi.Types

end

let label = Annot.nolabel "PostgresCodeGeneration"

module QueryMap = BaseMap.Make(
  struct
    type t = S.sqlquery
    let compare = Pervasives.compare
  end
)

module UpdateMap = BaseMap.Make(
  struct
    type t = (S.query option * Q.expr QD.update)
    let compare = Pervasives.compare
  end
)

type env = {
  ty_init : [ `foreign of string | `type_ of ([`enum | `composite of string list] * string * string) | `blob ] StringListMap.t;
  (* List of queries which create table *)
  tb_init : string list;
  (* tb_default *)
  tb_default : Q.ty StringListMap.t;
  (* query (id of prepared statement, string query) *)
  q_prepared : (string * string) QueryMap.t;
  (* delete (id of prepared statement, string query) *)
  d_prepared : (string * string) QueryMap.t;
  (* update (id of prepared statement, string query) *)
  u_prepared : (string * string) UpdateMap.t;
  gamma : QmlTypes.gamma;
  annotmap : Q.annotmap;
  schema : S.t
}

module Generator =
struct

  let random_stamp = BaseRandom.max_int ()

  (* http://www.postgresql.org/docs/8.1/static/sql-keywords-appendix.html#KEYWORDS-TABLE
     cat sqlkeywords | cut  -f 1,2 | grep -v "non-reserved" | grep reserved | cut -f 1 | sed "s/\(.*\)/\"\1\";/g"
  *)
  let pg_keywords = StringSet.from_list [
    "ALL";
    "ANALYSE";
    "ANALYZE";
    "AND";
    "ANY";
    "ARRAY";
    "AS";
    "ASC";
    "ASYMMETRIC";
    "AUTHORIZATION";
    "BETWEEN";
    "BINARY";
    "BOTH";
    "CASE";
    "CAST";
    "CHECK";
    "COLLATE";
    "COLUMN";
    "CONSTRAINT";
    "CREATE";
    "CROSS";
    "CURRENT_DATE";
    "CURRENT_ROLE";
    "CURRENT_TIME";
    "CURRENT_TIMESTAMP";
    "CURRENT_USER";
    "DEFAULT";
    "DEFERRABLE";
    "DESC";
    "DISTINCT";
    "DO";
    "ELSE";
    "END";
    "EXCEPT";
    "FALSE";
    "FOR";
    "FOREIGN";
    "FREEZE";
    "FROM";
    "FULL";
    "GRANT";
    "GROUP";
    "HAVING";
    "ILIKE";
    "IN";
    "INITIALLY";
    "INNER";
    "INTERSECT";
    "INTO";
    "IS";
    "ISNULL";
    "JOIN";
    "LEADING";
    "LEFT";
    "LIKE";
    "LIMIT";
    "LOCALTIME";
    "LOCALTIMESTAMP";
    "NATURAL";
    "NEW";
    "NOT";
    "NOTNULL";
    "NULL";
    "OFF";
    "OFFSET";
    "OLD";
    "ON";
    "ONLY";
    "OR";
    "ORDER";
    "OUTER";
    "OVERLAPS";
    "PLACING";
    "PRIMARY";
    "REFERENCES";
    "RIGHT";
    "SELECT";
    "SESSION_USER";
    "SIMILAR";
    "SOME";
    "SYMMETRIC";
    "TABLE";
    "THEN";
    "TO";
    "TRAILING";
    "TRUE";
    "UNION";
    "UNIQUE";
    "USER";
    "USING";
    "VERBOSE";
    "WHEN";
    "WHERE";
  ]

  let is_pg_keyworkds s = StringSet.mem (String.uppercase s) pg_keywords

  let pp_pgfield fmt s =
    if is_pg_keyworkds s then Format.fprintf fmt "\"%s\"" s
    else Format.pp_print_string fmt s

  let pp_pgfields ?(paren=true) fmt l = match paren, l with
    | true, (t::q'::q) ->
        Format.fprintf fmt "(%a).%a"
          pp_pgfield t
          (Format.pp_list "." pp_pgfield) (q'::q)
    | _ -> (Format.pp_list "." pp_pgfield) fmt l

  let pp_pgqfields fmt fields =
    pp_pgfields ~paren:true fmt
      (List.map (function | `string s -> s | _ -> assert false) fields)

  let pp_pgname = pp_pgfield

  let pg_types = [
    (Api.Types.binary,     "Bytea",           "bytea");
    (Api.Types.bool,       "Bool",            "boolean");
  ]

  let command_to_string = function
    | `select -> "SELECT"
    | `delete -> "DELETE"

  let get_pg_native_type gamma ty =
    let rec aux t =
      match t with
      | Q.TypeName ([a], s) when Q.TypeIdent.to_string s = Api.Types.list ->
          begin match aux a with
          | Some (_, "TEXT") -> Some ("StringArray1", "TEXT[]")
          | Some (_, "FLOAT") -> Some ("FloatArray1", "FLOAT[]")
          | Some (_, "INT8") -> Some ("IntArray1", "INT8[]")
          | _ -> None
          end
      | Q.TypeName (l, s) ->
          let st = Q.TypeIdent.to_string s in
          begin match List.find_opt (fun (x,_,_) -> x = st) pg_types with
          | None ->
              aux (QmlTypesUtils.Inspect.find_and_specialize gamma s l)
          | Some (_,x,y) -> Some (x, y)
          end
      | Q.TypeConst Q.TyFloat  -> Some ("Float", "FLOAT")
      | Q.TypeConst Q.TyInt    -> Some ("Int", "INT8")
      | Q.TypeConst Q.TyString -> Some ("String", "TEXT")
      | _ -> None
    in
    aux ty

  let make_env gamma annotmap schema = {
    tb_init = ["CREATE OR REPLACE LANGUAGE plpgsql"];
    ty_init = StringListMap.empty;
    tb_default = StringListMap.empty;
    q_prepared = QueryMap.empty;
    d_prepared = QueryMap.empty;
    u_prepared = UpdateMap.empty;
    gamma; annotmap; schema;
  }

  let letins bindings (env, e) =
    let annotmap, e =
      List.fold_left
        (fun (annotmap, letin) binding ->
           C.letin annotmap [binding] letin
        ) (env.annotmap, e) bindings
    in {env with annotmap}, e

  let get_node ~context gamma schema path =
    try
      S.get_node gamma schema path
    with Base.NotImplemented s ->
      QmlError.error context
        "Can not generate postgres access because : %s is not yet implemented"
        s

  let pp_table_name = (Format.pp_list "_" Format.pp_print_string)

  let opa_to_data
      ?(is_list=false)
      ({gamma; annotmap; ty_init; _} as env)
      path expr =
    let ty = QmlAnnotMap.find_ty (Annot.annot (Q.Label.expr expr)) annotmap in
    let project_list_opt annotmap to_pg_data =
      if not is_list then
        let annotmap, enum = to_pg_data annotmap ty expr in
        C.record annotmap ["String", enum]
      else
        let lty = (* To handle list case QIn as example *)
          let rec aux t =
            match t with
            | Q.TypeName ([a], s) when Q.TypeIdent.to_string s = Api.Types.list -> Some a
            | Q.TypeName (l, s) -> aux (QmlTypesUtils.Inspect.find_and_specialize gamma s l)
            | _ -> None
          in aux ty
        in
        match lty with
        | None ->
          let annotmap, enum = to_pg_data annotmap ty expr in
          C.record annotmap ["String", enum]
        | Some aty ->
          let arg = Ident.next "x" in
          let annotmap, earg = C.ident annotmap arg aty in
          let annotmap, body = to_pg_data annotmap aty earg in
          let annotmap, f = C.lambda annotmap [(arg, aty)] body in
          let annotmap, map =
            OpaMapToIdent.typed_val ~label Api.List.map annotmap gamma
          in
          let annotmap, l = C.apply env.gamma annotmap map [f; expr] in
          C.record annotmap ["StringArray1", l]
    in
    match StringListMap.find_opt path ty_init with
    | Some (`type_ (`enum, _, _)) ->
      let to_pg_data annotmap ty expr =
        let annotmap, sum_to_enum =
          OpaMapToIdent.typed_val ~label ~ty:[ty] Api.Db.sum_to_enum annotmap gamma in
        C.apply gamma annotmap sum_to_enum [expr]
      in
      let annotmap, e = project_list_opt annotmap to_pg_data in
      {env with annotmap}, e
    | Some `blob ->
      let to_pg_data annotmap ty expr =
        let annotmap, ser =
          OpaMapToIdent.typed_val ~ty:[ty] ~label Api.serialize annotmap gamma in
        C.apply gamma annotmap ser [expr]
      in
      let annotmap, e = project_list_opt annotmap to_pg_data in
      {env with annotmap}, e
    | Some _ -> assert false
    | None ->
        match get_pg_native_type gamma ty with
        | Some (fld, _) ->
            let annotmap, e = C.record annotmap [fld, expr] in
            {env with annotmap}, e
        | None ->
            Format.eprintf "%a %a\n%!" QmlPrint.pp#ty ty (Format.pp_list "," Format.pp_print_string) path;
            raise Not_found

  let pp_type_as_pgtype ?(path=[]) env fmt ty =
    match StringListMap.find_opt path env.ty_init with
    | Some (`foreign _) -> assert false
    | Some (`type_ (_,name,_)) -> Format.pp_print_string fmt name
    | Some (`blob) -> Format.pp_print_string fmt "TEXT"
    | None ->
        match get_pg_native_type env.gamma ty with
        | Some (_, t) -> Format.pp_print_string fmt t
        | None -> raise Not_found


  (* ******************************************************)
  (* QUERYING *********************************************)
  (* ******************************************************)
  let flatten_qfields flds =
    let rec aux rpath acc flds =
      List.fold_left
        (fun acc (s, u) ->
           let s = match s with [`string s] -> s | _ -> assert false in
           match u with
           | QD.QFlds flds -> aux (s::rpath) acc flds
           | u -> (List.rev (s::rpath), u)::acc)
        acc flds
    in List.rev (aux [] [] flds)

  let preprocess_query ~tbl ({gamma; annotmap; ty_init; _} as env) q =
    let rec aux path (annotmap, bindings) q =
      match StringListMap.find_opt (List.rev path) ty_init with
      | Some (`type_ (`enum, _, _) | `blob) ->
          let rec to_expr annotmap q =
            match q with
            | QD.QEq (e, _) -> annotmap, e
            | QD.QFlds flds ->
                let annotmap, flds = List.fold_left_map
                  (fun annotmap (s, q) ->
                     let annotmap, e = to_expr annotmap q in
                     let s = match s with [`string s] -> s | _ -> assert false in
                     annotmap, (s, e)
                  ) annotmap flds
                in C.record annotmap flds
            | _ -> assert false
          in begin match q with
          | QD.QEq _ | QD.QGt _ | QD.QLt _ | QD.QIn _
          | QD.QGte _ | QD.QLte _ | QD.QNe _ -> (annotmap, bindings), q
          | q ->
              let annotmap, e = to_expr annotmap q in
              (annotmap, bindings), QD.QEq (e, false)
          end
      | Some `foreign _ -> assert false
      | _ -> (
          match q with
          | QD.QFlds flds ->
              let (annotmap, bindings), flds = List.fold_left_map
                (fun (annotmap, bindings) (s, q) ->
                   let (annotmap, bindings), q =
                     let p = match s with | [`string s] -> s | _ -> assert false in
                     aux (p::path) (annotmap, bindings) q in
                   (annotmap, bindings), (s, q))
                (annotmap, bindings) flds
              in
              (annotmap, bindings), QD.QFlds flds
          | QD.QEq (e, b) ->
              let ty = QmlAnnotMap.find_ty (Annot.annot (Q.Label.expr e)) annotmap in
              begin match QmlTypesUtils.Inspect.follow_alias_noopt_private gamma ty with
              | Q.TypeRecord (Q.TyRow (flds, _)) ->
                  let (annotmap, bindings), flds =
                    List.fold_left_map
                      (fun (annotmap, bindings) (s, ty) ->
                         let annotmap, e = C.dot gamma annotmap e s in
                         let i = Ident.next "qdot" in
                         let annotmap, ie = C.ident annotmap i ty in
                         let acc, q = aux (s::path) (annotmap, (i,e)::bindings) (QD.QEq (ie, false)) in
                         acc, ([`string s], q)
                      )
                      (annotmap, bindings) flds
                  in (annotmap, bindings), QD.QFlds flds
              | _ -> (annotmap, bindings), QD.QEq (e, b)
              end
          | QD.QAnd (q0, q1) ->
              binop path (annotmap, bindings) (fun q0 q1 -> QD.QAnd (q0,q1)) q0 q1
          | QD.QOr (q0, q1)  ->
              binop path (annotmap, bindings) (fun q0 q1 -> QD.QOr (q0,q1)) q0 q1
          | _ -> (annotmap, bindings), q
        )
    and binop path (annotmap, bindings) rebuild q0 q1 =
      let (annotmap, bindings), q0 = aux path (annotmap, bindings) q0 in
      let (annotmap, bindings), q1 = aux path (annotmap, bindings) q1 in
      (annotmap, bindings), rebuild q0 q1
    in
    let (annotmap, bindings), q = aux [tbl] (annotmap, []) q in
    {env with annotmap}, bindings, q

  let pp_postgres_genquery pp_expr fmt (q:(_, _) QmlAst.Db.query) =
    let rec aux fmt q =
      let pp x = Format.fprintf fmt x in
      match q with
      | QD.QEq  (e, _)    -> pp " = %a" (pp_expr []) e
      | QD.QGt   e    -> pp " > %a" (pp_expr []) e
      | QD.QLt   e    -> pp " < %a" (pp_expr []) e
      | QD.QGte  e    -> pp " >= %a" (pp_expr []) e
      | QD.QLte  e    -> pp " <= %a" (pp_expr []) e
      | QD.QNe   e    -> pp " <> %a" (pp_expr []) e
      | QD.QIn   e    -> pp " = ANY (%a)" (pp_expr []) e
      | QD.QMod  _    -> assert false
      | QD.QExists false   -> pp " = NULL"
      | QD.QExists true    -> pp " <> NULL"
      | QD.QOr  (q0, q1) ->
          pp "%a OR %a"
            aux q0
            aux q1
      | QD.QAnd (q0, q1) ->
          pp "%a AND %a"
            aux q0
            aux q1
      | QD.QNot  _     -> assert false
      | QD.QFlds flds  ->
          match flatten_qfields flds with
          | [f,q] ->
              pp "%a %a"
                (pp_pgfields ~paren:true) f
                aux q
          | flds ->
              pp "(%a)"
                (Format.pp_list " AND "
                   (fun _fmt (f, q) ->
                      pp "%a %a"
                        (pp_pgfields ~paren:true) f
                        aux q
                   )) flds
    in
    match q with
    | QD.QFlds [] -> ()
    | _ ->
        let pp x = Format.fprintf fmt x in
        pp " WHERE ";
        aux fmt q

  let pp_postgres_sqlquery ~command fmt q o =
    let pos = ref 0 in
    let pp x = Format.fprintf fmt x in
    pp "%s " (command_to_string command);
    begin match command with
    | `select ->
        (match q.QD.sql_fds with
         | [] -> pp "* "
         | _ ->
             BaseFormat.pp_list "," (BaseFormat.pp_list "." pp_pgfield)
               fmt q.QD.sql_fds
        );
    | `delete -> ()
    end;
    pp " FROM ";
    (BaseFormat.pp_list "," Format.pp_print_string) fmt q.QD.sql_tbs;
    (match q.QD.sql_ops with
     | None -> ()
     | Some sql_ops ->
         pp_postgres_genquery
           (fun _ fmt -> function
            | `expr _ -> incr pos; Format.fprintf fmt "$%d" !pos
            | `bind s -> pp_pgfield fmt s
           ) fmt sql_ops);
    (match o.QD.sort with
     | None -> ()
     | Some flds -> Format.fprintf fmt " ORDER BY %a"
         (Format.pp_list ", "
            (fun fmt (flds, e) ->
               let o =
                 let rec aux e =
                   match e with
                   | Q.Record (_, ["up", _]) -> "ASC"
                   | Q.Record (_, ["down", _]) -> "DESC"
                   | Q.Coerce (_, e, _) -> aux e
                   | _ -> failwith "order must be statically known"
                 in aux e
               in
               Format.fprintf fmt "%a %s"
                 pp_pgqfields flds
                 o
            )
         ) flds
    );
    (match o.QD.limit with
     | None -> ()
     | Some _ -> incr pos; Format.fprintf fmt " LIMIT $%d" !pos);
    (match o.QD.skip with
     | None -> ()
     | Some _ -> incr pos; Format.fprintf fmt " OFFSET $%d" !pos)

  let prepared_statement_for_query =
    let fresh_id =
      let fresh = Fresh.fresh_factory (fun x -> x) in
      fun s -> Format.sprintf "%s_%d_%d" s (fresh ()) random_stamp
    in
    fun
      ?(command=`select)
      ({annotmap; q_prepared; d_prepared; _} as env)
      ((sqlquery, options) as query) ->
      let buffer = Buffer.create 256 in
      let fmt = Format.formatter_of_buffer buffer in
      pp_postgres_sqlquery ~command fmt sqlquery options;
      Format.pp_print_flush fmt ();
      let qid = fresh_id (command_to_string command) in
      match command with
      | `select ->
          let q_prepared = QueryMap.add query (qid, Buffer.contents buffer) q_prepared in
          {env with annotmap; q_prepared}
      | `delete ->
          let d_prepared = QueryMap.add query (qid, Buffer.contents buffer) d_prepared in
          {env with annotmap; d_prepared}

  let execute_statement
      ?(command=`select)
      ({gamma; annotmap; q_prepared; d_prepared; _} as env)
      next node (kpath, query) =
    let qid, _ = try
      QueryMap.find query
        (match command with
         | `select -> q_prepared
         | `delete -> d_prepared
        )
    with
      Not_found -> OManager.i_error "Can't found prepared statement"
    in
    let annotmap, database =
      C.ident annotmap node.S.database.S.ident node.S.database.S.dbty in
    let annotmap, qid = C.string annotmap qid in
    let env = {env with annotmap} in
    let ({annotmap; _} as env), args =
      let {QD. sql_ops; sql_tbs; _} = fst query in
      match sql_ops with
      | None -> env, []
      | Some sql_ops ->
          let rec aux env path args ops =
            let binop q0 q1 =
              let env, args = aux env path args q0 in
              aux env path args q1
            in
            match ops with
            | QD.QEq     (`expr e, _)
            | QD.QGt     (`expr e)
            | QD.QLt     (`expr e)
            | QD.QGte    (`expr e)
            | QD.QLte    (`expr e)
            | QD.QNe     (`expr e) ->
              let env, arg = opa_to_data env (List.rev path) e in
              env, arg::args
            | QD.QIn     (`expr e) ->
              let env, arg = opa_to_data ~is_list:true env (List.rev path) e in
              env, arg::args
            | QD.QFlds flds ->
                List.fold_left
                  (fun (env, args) (f, q) ->
                     let s = match f with | [`string s] -> s | _ -> assert false in
                     aux env (s::path) args q
                  ) (env, args) flds
            | QD.QAnd (q0, q1) -> binop q0 q1
            | QD.QOr  (q0, q1) -> binop q0 q1
            | QD.QNot q -> aux env path args q
            | _ -> env, args
          in
          match sql_tbs with
          | [] -> assert false
          | [tbl] -> aux env [tbl] [] sql_ops
          | _ ->
              let table_from_field =
                let map = List.fold_left
                  (fun map tbl ->
                     let ty =
                       let dty = match (next tbl).S.kind with
                         | S.SetAccess (S.DbSet ty, _, _, _) -> ty
                         | _ -> assert false
                       in
                       QmlTypesUtils.Inspect.follow_alias_noopt_private gamma dty
                     in
                     match ty with
                     | Q.TypeRecord (Q.TyRow (flds, _)) ->
                         List.fold_left
                           (fun map (f, _) -> StringMap.add f tbl map)
                           map flds
                     | _ -> assert false
                  ) StringMap.empty sql_tbs
                in fun field -> StringMap.find field map
              in
              let rec aux0 sql_ops acc =
                let binop q0 q1 acc =
                  aux0 q1 (aux0 q0 acc)
                in
                match sql_ops with
                | QD.QFlds flds ->
                    List.fold_left
                      (fun (env, args) (f, q) ->
                         let s = match f with [`string s] -> s | _ -> assert false in
                         aux env [s; table_from_field s] args q)
                      acc flds
                | QD.QAnd (q0, q1)
                | QD.QOr (q0, q1) -> binop q0 q1 acc
                | _ -> assert false
              in aux0 sql_ops (env, [])
    in
    let annotmap, args =
      let {QD. limit; skip; _}  = snd query in
      let annotmap, args = match limit with | None -> annotmap, args
        | Some limit ->
            let annotmap, arg = C.record annotmap ["Int", limit] in
            annotmap, arg :: args
      in
      let annotmap, args = match skip with | None -> annotmap, args
        | Some skip ->
            let annotmap, arg = C.record annotmap ["Int", skip] in
            annotmap, arg :: args
      in
      annotmap, args
    in
    let annotmap, args = C.rev_list (annotmap, gamma) args in
    match command with
    | `select ->
        let annotmap, def = node.S.default annotmap in
        let build = match kpath with
          | `dbset   -> Api.Db.build_dbset
          | `uniq    -> Api.Db.build_uniq
          | `option    -> Api.Db.build_option
        in
        let annotmap, build =
          OpaMapToIdent.typed_val ~label ~ty:[node.S.ty]
            build annotmap gamma
        in
        let annotmap, dbset = C.apply gamma annotmap build [database; qid; args; def] in
        {env with annotmap}, dbset
    | `delete ->
        let remove = Api.Db.remove in
        let annotmap, remove = OpaMapToIdent.typed_val ~label remove annotmap gamma in
        let annotmap, remove = C.apply gamma annotmap remove [database; qid; args] in
        {env with annotmap}, remove


  (* ******************************************************)
  (* UPDATING *********************************************)
  (* ******************************************************)
  let preprocess_update ~tbl ({gamma; annotmap; ty_init; _} as env) u =
    let rec aux path (annotmap, bindings) u =
      match StringListMap.find_opt (List.rev path) ty_init with
      | Some (`type_ (`enum, _, _) | `blob) ->
          let rec to_expr annotmap u =
            match u with
            | QD.UExpr e -> annotmap, e
            | QD.UFlds (flds:(Q.expr, Q.expr QD.update) QD.fields) ->
                let annotmap, flds = List.fold_left_map
                  (fun annotmap (s, u) ->
                     let annotmap, e = to_expr annotmap u in
                     let s = match s with [`string s] -> s | _ -> assert false in
                     annotmap, (s, e)
                  ) annotmap flds
                in C.record annotmap flds
            | _ -> assert false
          in let annotmap, e = to_expr annotmap u in
          (annotmap, bindings), QD.UExpr (e:Q.expr)
      | Some `foreign _ -> assert false
      | _ -> (
          match u with
          | QD.UFlds flds ->
              let (annotmap, bindings), flds = List.fold_left_map
                (fun (annotmap, bindings) (s, u) ->
                   let (annotmap, bindings), u =
                     let p = match s with | [`string s] -> s | _ -> assert false in
                     aux (p::path) (annotmap, bindings) u in
                   (annotmap, bindings), (s, u))
                (annotmap, bindings) flds
              in
              (annotmap, bindings), QD.UFlds flds
          | QD.UExpr e ->
              let ty = QmlAnnotMap.find_ty (Annot.annot (Q.Label.expr e)) annotmap in
              begin match QmlTypesUtils.Inspect.follow_alias_noopt_private gamma ty with
              | Q.TypeRecord (Q.TyRow (flds, _)) ->
                  let (annotmap, bindings), flds =
                    List.fold_left_map
                      (fun (annotmap, bindings) (s, ty) ->
                         let annotmap, e = C.dot gamma annotmap e s in
                         let i = Ident.next "udot" in
                         let annotmap, ie = C.ident annotmap i ty in
                         let acc, u = aux (s::path) (annotmap, (i,e)::bindings) (QD.UExpr ie) in
                         acc, ([`string s], u)
                      )
                      (annotmap, bindings) flds
                  in (annotmap, bindings), QD.UFlds flds
              | _ -> (annotmap, bindings), QD.UExpr e
              end
          | QD.UIncr _
          | QD.UId _
          | QD.UAppend _
          | QD.UAppendAll _
          | QD.URemove _
          | QD.URemoveAll _
          | QD.UPop
          | QD.UShift -> (annotmap, bindings), u
        )
    in
    let (annotmap, bindings), u = aux [tbl] (annotmap, []) u in
    {env with annotmap}, bindings, u

  let flatten_ufields flds =
    let rec aux rpath acc flds =
      List.fold_left
        (fun acc (s, u) ->
           let s = match s with [`string s] -> s | _ -> assert false in
           match u with
           | QD.UFlds flds -> aux (s::rpath) acc flds
           | u -> (List.rev (s::rpath), u)::acc)
        acc flds
    in aux [] [] flds

  let lexi_fields {ty_init; _} path flds =
    let rec aux  path acc flds =
      List.fold_left
        (fun acc (s, u) ->
           let s = match s with [`string s] -> s | _ -> assert false in
           let path = s::path in
           match StringListMap.find_opt (List.rev path) ty_init with
           | Some (`type_ (`enum, _, _) | `blob) -> StringMap.add s (`op u) acc
           | _ ->
               match StringMap.find_opt s acc with
               | None ->
                   begin match u with
                   | QD.UFlds flds -> StringMap.add s (`sub (aux path StringMap.empty flds)) acc
                   | _ -> StringMap.add s (`op u) acc
                   end
               | Some (`sub sub) ->
                   begin match u with
                   | QD.UFlds flds -> StringMap.add s (`sub (aux path sub flds)) acc
                   | _ -> assert false
                   end
               | Some (`op _) -> assert false
        ) acc flds
    in aux path StringMap.empty flds

  let pp_update ~tbl pp_expr fmt (u:_ QmlAst.Db.update) =
    Format.fprintf fmt "UPDATE %a SET " pp_pgname tbl;
    match u with
    | QD.UFlds flds ->
        let flds = flatten_ufields flds in
        Format.pp_list ","
          (fun fmt (p, u) ->
             match u with
             | QD.UIncr e ->
                 Format.fprintf fmt "%a = %a + %a"
                   (pp_pgfields ~paren:false) p
                   (pp_pgfields ~paren:false) p
                   (pp_expr (tbl::p)) e
             | QD.UExpr e ->
                 Format.fprintf fmt "%a = %a"
                   (pp_pgfields ~paren:false) p
                   (pp_expr (tbl::p)) e
             | _ -> assert false
          ) fmt flds
    | QD.UExpr _
    | QD.UIncr _ -> assert false
    | QD.UId _
    | QD.UAppend _
    | QD.UAppendAll _
    | QD.URemove _
    | QD.URemoveAll _
    | QD.UPop
    | QD.UShift ->
        (* External table? Embedded? Mixed? *)
          assert false

  let pp_insert env ~tbl pp_expr fmt (u:_ QmlAst.Db.update) =
    match u with
    | QD.UFlds flds ->
        let start = ref true in
        let lexmap = lexi_fields env [tbl] flds in
        Format.fprintf fmt "INSERT INTO %a(%a) VALUES(" pp_pgname tbl
          (StringMap.pp ""
             (fun fmt s _ ->
                (if !start then start:=false else Format.fprintf fmt " ,");
                pp_pgfield fmt s))
          lexmap;
        let rec aux path n =
          match n with
          | `op (QD.UIncr e | QD.UExpr e) ->
              pp_expr (List.rev path) fmt e
          | `op _ -> assert false
          | `sub lexmap ->
              match StringListMap.find_opt (List.rev path) env.ty_init with
              | Some (`type_ (`composite flds, _, _)) ->
                  Format.fprintf fmt "ROW(%a)"
                    (Format.pp_list ", "
                       (fun fmt s ->
                          match StringMap.find_opt s lexmap with
                          | None -> Format.pp_print_string fmt "NULL"
                          | Some n ->
                              aux (s::path) n)
                    ) flds
              | _ -> assert false (* ? *)
        in
        let start = ref true in
        StringMap.pp ""
          (fun fmt s n ->
             (if !start then start:=false else Format.fprintf fmt " ,");
             aux [s;tbl] n)
          fmt lexmap;
        Format.pp_print_string fmt ")"

    | QD.UExpr _
    | QD.UIncr _ -> assert false
    | QD.UId _
    | QD.UAppend _
    | QD.UAppendAll _
    | QD.URemove _
    | QD.URemoveAll _
    | QD.UPop
    | QD.UShift ->
        (* External table? Embedded? Mixed? *)
        assert false

  let pp_postgres_insert_or_update env ~name ~tbl fmt q (u:_ QmlAst.Db.update) =
    let annotmap = env.annotmap in
    let aset = ref AnnotMap.empty in
    let pp_annot fmt i = Format.fprintf fmt "x%d" (Annot.to_int i) in
    let pp_expr path fmt e =
      let annot = Annot.annot (Q.Label.expr e) in
      aset := AnnotMap.add annot path !aset;
      pp_annot fmt annot
    in
    let pp x = Format.fprintf fmt x in
    pp "CREATE OR REPLACE FUNCTION %s(" name;
    let buffer = Buffer.create 256 in
    let fmt2 = Format.formatter_of_buffer buffer in
    let pp2 x = Format.fprintf fmt2 x in
    pp2 ")RETURNS VOID AS\n";
    pp2 "$$\n";
    pp2 "BEGIN\n";
    pp2 "    %a " (pp_update ~tbl pp_expr) u;
    begin match q with
    | Some (q, _) -> pp_postgres_genquery pp_expr fmt2 q;
    | _ -> ()
    end;
    pp2 ";\n";
    pp2 "    IF found THEN\n";
    pp2 "      RETURN;\n";
    pp2 "    END IF;\n";
    pp2 "    BEGIN\n";
    pp2 "      %a;\n" (pp_insert env ~tbl pp_expr) u;
    pp2 "    EXCEPTION WHEN unique_violation THEN\n";
    pp2 "    END;\n";
    pp2 "END;\n";
    pp2 "$$\n";
    pp2 "LANGUAGE plpgsql;\n";
    Format.pp_print_flush fmt2 ();
    let () =
      let pp_elt fmt a path =
        Format.fprintf fmt "%a %a"
          pp_annot a
          (pp_type_as_pgtype ~path env) (QmlAnnotMap.find_ty a annotmap)
      in
      let (max, p) = AnnotMap.max !aset in
      let set = AnnotMap.remove max !aset in
      AnnotMap.pp ", " pp_elt fmt set;
      pp_elt fmt max p
    in
    Format.pp_print_string fmt (Buffer.contents buffer);
    ()

  let prepared_statement_for_update =
    let fresh_id =
      let fresh = Fresh.fresh_factory (fun x -> x) in
      fun () -> Format.sprintf "update_%d_%d" (fresh ()) random_stamp
    in
    fun
      ({annotmap; u_prepared; _} as env)
      ~tbl
      query
      (update, update_options) ->
        let buffer = Buffer.create 256 in
        let fmt = Format.formatter_of_buffer buffer in
        let uid = fresh_id () in
        pp_postgres_insert_or_update env ~name:uid ~tbl fmt query update;
        (* TODO OPTIONS *)
        ignore (update_options);
        Format.pp_print_flush fmt ();
        let u_prepared = UpdateMap.add (query, update) (uid, Buffer.contents buffer) u_prepared in
        {env with annotmap; u_prepared}

  let execute_statement_for_update =
    fun
      ({gamma; annotmap; u_prepared; _} as env)
      ~tbl
      node query (update, _update_options) ->
        let procname, _ = UpdateMap.find (query, update) u_prepared in
        let (amap:(string list * Q.expr) AnnotMap.t) = AnnotMap.empty in
        let amap =
          match query with
          | None -> amap
          | Some (query , _) ->
              let _, amap =
                QmlAstWalk.DbWalk.Query.self_traverse_fold
                  (fun self tra (path, (amap:(string list * Q.expr) AnnotMap.t)) -> function
                   | QD.QEq (e, _) | QD.QGt e | QD.QLt e | QD.QGte e | QD.QLte e
                   | QD.QNe e | QD.QIn e ->
                       let annot = Annot.annot (Q.Label.expr e) in
                       path, AnnotMap.add annot (List.rev path, e) amap
                   | QD.QFlds flds ->
                       path, List.fold_left
                         (fun amap (f, q) ->
                            let s = match f with | [`string s] -> s | _ -> assert false in
                            let _, amap = self (s::path, amap) q in
                            amap
                         ) amap flds
                   | q -> tra (path, amap) q
                  ) ([], AnnotMap.empty) query
              in amap
        in
        let _, amap =
          QmlAstWalk.DbWalk.Update.self_traverse_fold
            (fun self tra (path, amap) -> function
             | QD.UExpr e
             | QD.UIncr e
             | QD.UAppend    e
             | QD.UAppendAll e
             | QD.URemove    e
             | QD.URemoveAll e
             | QD.UId (e, _) ->
                 let annot = Annot.annot (Q.Label.expr e) in
                 path, AnnotMap.add annot (List.rev path, e) amap
             | QD.UFlds flds ->
                 path, List.fold_left
                   (fun amap (f, q) ->
                      let s = match f with | [`string s] -> s | _ -> assert false in
                      let _, amap = self (s::path, amap) q in
                      amap
                   ) amap flds
             | q -> tra (path, amap) q
            ) ([], amap) update
        in
        let annotmap, database =
          C.ident annotmap node.S.database.S.ident node.S.database.S.dbty in
        let annotmap, procname =
          C.string annotmap procname in
        let ({annotmap; _} as env), args =
          AnnotMap.fold
            (fun _ (path, expr) (env, args) ->
               let env, arg = opa_to_data env (tbl::path) expr in
               env, arg::args
            ) amap ({env with annotmap}, [])
        in
        let annotmap, args =
          C.rev_list (annotmap, gamma) args in
        let annotmap, update_or_insert =
          OpaMapToIdent.typed_val ~label Api.Db.update_or_insert annotmap gamma in
        let annotmap, res =
          C.apply gamma annotmap update_or_insert [database; procname; args] in
        {env with annotmap}, res

  let post_projection gamma ~ty path annotmap =
    match path with
    | [] -> None
    | _ -> Some (
        let arg = Ident.next "x" in
        let rec aux path =
          match path with
          | [] -> C.ident annotmap arg ty
          | t::q ->
              let annotmap, e = aux q in
              C.dot gamma annotmap e t
        in
        let annotmap, dots = aux path in
        C.lambda annotmap [(arg, ty)] dots
      )

  let apply_post_projection env postproj kpath expr =
    match postproj env.annotmap with
    | None -> (env, expr)
    | Some (annotmap, f) ->
        let annotmap, r =
          match kpath with
          | `uniq   -> C.apply env.gamma annotmap f [expr]
          | `option ->
              let annotmap, map =
                OpaMapToIdent.typed_val ~label Api.Option.map annotmap env.gamma in
              C.apply env.gamma annotmap map [f; expr]
          | `dbset  ->
              let annotmap, map =
                OpaMapToIdent.typed_val ~label Api.DbSet.map annotmap env.gamma in
              C.apply env.gamma annotmap map [f; expr]
        in {env with annotmap}, r

  let query_to_sqlquery ~ty tbl query select embed =
    let postproj, select = match embed with
      | None ->
          (fun env _kpath expr -> (env, expr)), select
      | Some x ->
          let path = List.map (function QD.FldKey s -> s | _ -> assert false) x in
          let fld = List.map (function QD.FldKey s -> `string s | _ -> assert false) x in
          (fun env kpath expr ->
             apply_post_projection env
               (post_projection ~ty env.gamma path)
               kpath expr
          ),
          QD.SFlds [(fld, select)]
    in
    let sql_fds =
      match select with
      | QD.SId _ | QD.SSlice _->
          OManager.printf "This kind of projection is not yet implemented by PG driver";
          assert false
      | QD.SStar | QD.SNil -> []
      | QD.SFlds flds ->
          List.map
            (fun (field, s) ->
               begin match s with
               | QD.SStar | QD.SNil -> ()
               | _ -> OManager.printf "This kind of projection is not yet implemented by PG driver";
                   assert false
               end;
               tbl::
                 (List.map
                    (function `string s -> s
                     | _ -> OManager.printf "This kind of projection is not yet implemented by PG driver"; assert false
                    ) field
                 )
            ) flds
    in
    let rec aux q =
      let binop q0 q1 rb = rb (aux q0) (aux q1) in
      match q with
      | QD.QEq (e, b)  -> QD.QEq (`expr e, b)
      | QD.QGt e  -> QD.QGt (`expr e)
      | QD.QLt e  -> QD.QLt (`expr e)
      | QD.QGte e -> QD.QGte (`expr e)
      | QD.QLte e -> QD.QLte (`expr e)
      | QD.QNe e  -> QD.QNe (`expr e)
      | QD.QIn e  -> QD.QIn (`expr e)
      | QD.QMod i ->  QD.QMod i
      | QD.QOr  (q0, q1) -> binop q0 q1 (fun q0 q1 -> QD.QOr (q0, q1))
      | QD.QAnd (q0, q1) -> binop q0 q1 (fun q0 q1 -> QD.QAnd (q0, q1))
      | QD.QNot  q -> QD.QNot (aux q)
      | QD.QFlds flds ->
          let flds = List.map (fun (s,q) -> (s, aux q)) flds in
          QD.QFlds flds
      | QD.QExists b -> QD.QExists b
    in
    postproj, {QD. sql_ops = Option.map aux query; sql_tbs = [tbl]; sql_fds}

  let resolve_sqlaccess env next node (kpath, query) =
    let env = prepared_statement_for_query ~command:`select env query in
    execute_statement env next node (kpath, query)

  let resolve_sqldelete env next node (kpath, query) =
    let env = prepared_statement_for_query ~command:`delete env query in
    execute_statement ~command:`delete env next node (kpath, query)

  let resolve_sqlupdate ~tbl env node query embed (upd, opt) =
    let upd = match embed with
      | None -> upd
      | Some p ->
          List.fold_right
            (fun elt upd -> match elt with
             | QD.FldKey s -> QD.UFlds [([`string s], upd)]
             | _ -> assert false)
            p upd
    in
    let env, ubindings, upd = preprocess_update ~tbl env upd in
    let env, qbindings, query = match query with
      | Some (q, o) ->
          let e, b, q = preprocess_query ~tbl env q in
          e, b, Some (q, o)
      | None -> env, [], None
    in
    let env = prepared_statement_for_update env ~tbl query (upd, opt) in
    let env, e = execute_statement_for_update env ~tbl node query (upd, opt) in
    letins qbindings (letins ubindings (env, e))

  let setaccess_to_sqlacces ~tbl env node select query embed =
    let ty = node.S.ty in
    match query with
    | None ->
        let post, query = query_to_sqlquery ~ty tbl None select embed in
        env, [], `dbset, post, (query, QD.default_query_options)
    | Some (uniq, (q, o)) ->
        let env, bindings, q = preprocess_query ~tbl env q in
        let post, query = query_to_sqlquery ~ty tbl (Some q) select embed in
        env, bindings, (if uniq then `uniq else `dbset), post, (query, o)

  let resolve_sqlref ~tbl env next node query embed =
    assert (embed = None);
    let env, bindings, kpath, post, sqlquery =
      setaccess_to_sqlacces ~tbl env node QD.SStar query embed in
    (* read expression *)
    let env, read = resolve_sqlaccess env next node (kpath, sqlquery) in
    let env, read = letins bindings (env, read) in
    let env, read =
      let env, read = post env kpath read in
      let annotmap, read = C.lambda env.annotmap [] read in
      {env with annotmap}, read
    in

    (* exists expression: TODO need to be optimized (no fetching data) *)
    let env, exists = resolve_sqlaccess env next node (`option, sqlquery) in
    let env, exists = letins bindings (env, exists) in
    let env, exists = post env kpath exists in
    let env, exists =
      let annotmap = env.annotmap in
      let annotmap, any = QmlAstCons.TypedPat.any annotmap in
      let annotmap, true_ = C._true (annotmap, env.gamma) in
      let annotmap, false_ = C._false (annotmap, env.gamma) in
      let annotmap, exists =
        QmlAstCons.TypedPat.match_option annotmap env.gamma exists any true_ false_
      in
      let annotmap, exists = C.lambda annotmap [] exists in
      {env with annotmap}, exists
    in

    (* write expression *)
    let env, write =
      let i = Ident.next "x" in
      let annotmap, x = C.ident env.annotmap i node.S.ty in
      let upd = QD.UExpr x in
      let env = {env with annotmap} in
      let env, write =
        let query = Option.map snd query in
        resolve_sqlupdate ~tbl env node query embed (upd, QD.default_update_options)
      in
      let annotmap, write = C.lambda env.annotmap [i, node.S.ty] write in
      {env with annotmap}, write
    in

    (* remove expression *)
    let env, remove =
      let env, remove = resolve_sqldelete env next node (kpath, sqlquery) in
      let annotmap, remove = C.lambda env.annotmap [] remove in
      {env with annotmap}, remove
    in

    (* Db.builder *)
    let annotmap = env.annotmap in
    let annotmap, id = C.string annotmap "" in
    let annotmap, more =
        C.record annotmap [
          "write", write;
          "remove", remove;
        ]
    in
    let annotmap, engine = C.cheap_void annotmap env.gamma in
    let annotmap, builder = C.record annotmap [
      "id",     id;
      "read",   read;
      "exists", exists;
      "more",   more;
      "engine", engine;
    ]
    in
    letins bindings ({env with annotmap}, builder)

  let path ~context
      ({gamma; schema; _} as env)
      (label, dbpath, kind, select)
      =
    let node = get_node ~context gamma schema dbpath in
    match node.S.database.S.options.QD.backend with
    | `postgres ->
        begin
          let string_path () =
            List.map
              (function | QD.FldKey str -> str | _ -> assert false)
              (List.tl dbpath)
          in
          let plain_to_sqlaccess node =
            let path = string_path () in
            let ty =
              let rec aux = function
                  [] -> node.S.ty
                | t::q -> Q.TypeRecord (Q.TyRow ([(t, aux q)], None))
              in aux path
            in
            let node = {node with
              S.ty;
              default = fun ?select annotmap ->
                (* TODO: fix select *)
                let rec aux annotmap = function
                  | [] -> node.S.default ?select annotmap
                  | t::q ->
                      let annotmap, e = aux annotmap q in
                      C.record annotmap [(t, e)]
                in aux annotmap path
                       }
            in
            (fun env kpath expr ->
               apply_post_projection env
                 (post_projection env.gamma ~ty path)
                 kpath expr
            ),
            node,
            ({QD. sql_ops=None; sql_tbs=["_default"]; sql_fds=[path]}, QD.default_query_options)
          in
          let next s =
            get_node ~context gamma schema (dbpath@[QD.FldKey s])
          in
          let next_for_sql s =
            let rec aux = function
              | t::_::[] -> t::QD.FldKey s::[]
              | t::q -> t::(aux q)
              | _ -> assert false
            in
            get_node ~context gamma schema (aux dbpath)
          in
          match kind, node.S.kind with
          | QD.Default, S.SqlAccess query ->
              resolve_sqlaccess env next_for_sql node (`dbset, query)
          | QD.Default, S.SetAccess (S.DbSet _, [tbl], query, embed) ->
              let env, bindings, kpath, post, query =
                setaccess_to_sqlacces ~tbl env node select query embed in
              let env, access = resolve_sqlaccess env next node (kpath, query) in
              let env, access = letins bindings (env, access) in
              post env kpath access
          | QD.Option, S.SetAccess (S.DbSet _, [tbl], query, embed) ->
              let env, bindings, kpath, post, query =
                setaccess_to_sqlacces ~tbl env node select query embed in
              assert (kpath = `uniq);
              let env, access = resolve_sqlaccess env next node (`option, query) in
              let env, access = letins bindings (env, access) in
              post env `option access
          | QD.Ref,    S.SetAccess (S.DbSet _, [tbl], query, embed) ->
              resolve_sqlref ~tbl env next node query embed

          | QD.Update (upd, opt), S.SetAccess (S.DbSet _, [tbl], query, embed) ->
              let query = Option.map snd query in
              resolve_sqlupdate ~tbl env node query embed (upd, opt)

          | QD.Default, S.Plain ->
              let post, node, query = plain_to_sqlaccess node in
              let env, access = resolve_sqlaccess env next node (`uniq, query) in
              post env `uniq access
          | QD.Option, S.Plain ->
              let post, node, query = plain_to_sqlaccess node in
              let env, access = resolve_sqlaccess env next node (`option, query) in
              post env `option access
          | QD.Update (upd, opt), S.Plain ->
              let strpath = string_path () in
              let annotmap, _0 = C.int env.annotmap 0 in
              let upd = QD.UFlds [
                [`string "_id"], QD.UExpr _0;
                (List.map (fun s -> `string s) strpath), upd
              ] in
              let query = QD.QFlds [[`string "_id"], QD.QEq (_0, false)], QD.default_query_options in
              resolve_sqlupdate ~tbl:"_default" {env with annotmap} node (Some query) None (upd, opt)
          | _ -> assert false
        end
    | _ -> env, Q.Path (label, dbpath, kind, select)

  let rec type_from_ty env path tpath ty =
    match ty with
    | Q.TypeRecord Q.TyRow (fields, _) ->
        let tra env = List.fold_left
          (fun env (s, t) -> type_from_ty env path (s::tpath) t)
          env fields
        in
        begin match tpath with
        | [] -> tra env (*First level: don't create a composite type *)
        | _ ->
            let env = tra env in
            let buffer = Buffer.create 256 in
            let fmt = Format.formatter_of_buffer buffer in
            let tpath = List.rev (tpath@path) in
            let name = Format.sprintf "%a" pp_table_name tpath in
            Format.fprintf fmt "CREATE TYPE %a AS (" pp_pgname name;
            Format.pp_list ","
              (fun fmt (s, t) ->
                 Format.fprintf fmt "%a %a"
                   pp_pgfield s
                   (pp_type_as_pgtype ~path:(tpath@[s]) env) t;
              ) fmt fields;
            Format.fprintf fmt ")";
            Format.pp_print_flush fmt ();
            let q = Buffer.contents buffer in
            let fields = List.map fst fields in
            {env with ty_init = StringListMap.add tpath (`type_ (`composite fields, name, q)) env.ty_init}
        end
    | Q.TypeName (l, s) ->
        if Option.is_some (get_pg_native_type env.gamma ty) then env
        else
          type_from_ty env path tpath (QmlTypesUtils.Inspect.find_and_specialize env.gamma s l)
    | Q.TypeSum (Q.TyCol (cols, _)) ->
        let tpath = List.rev (tpath@path) in
        begin try
          let buffer = Buffer.create 256 in
          let fmt = Format.formatter_of_buffer buffer in
          let name = Format.sprintf "%a" pp_table_name tpath in
          Format.fprintf fmt "CREATE TYPE %a AS ENUM (" pp_pgname name;
          Format.pp_list ","
            (fun fmt flds ->
               match flds with
               | [(case, ty)] when QmlTypesUtils.Inspect.is_type_void env.gamma ty ->
                   Format.fprintf fmt "'%s'" case;
               | _ -> raise Not_found
            ) fmt cols;
          Format.fprintf fmt ")";
          Format.pp_print_flush fmt ();
          let q = Buffer.contents buffer in
          {env with ty_init = StringListMap.add tpath (`type_ (`enum, name, q)) env.ty_init}
        with Not_found ->
          OManager.warning
            ~wclass:WarningClass.dbgen_postgres
            "Data of type @{<bright>%a@} at path @{<bright>/%a@} will be managed as a blob\n"
            QmlPrint.pp#ty ty
            (Format.pp_list "/" Format.pp_print_string) tpath;
          {env with ty_init = StringListMap.add tpath (`blob) env.ty_init}
        end
    | Q.TypeConst _ -> env
    | _ ->
        let tpath = List.rev (tpath@path) in
        OManager.warning
          ~wclass:WarningClass.dbgen_postgres
          "Data of type @{<bright>%a} at path @{<bright>/%a@} will be managed as a blob\n"
          QmlPrint.pp#ty ty
          (Format.pp_list "/" Format.pp_print_string) tpath;
        {env with ty_init = StringListMap.add tpath (`blob) env.ty_init}

  let rec table_from_ty
      ({gamma; tb_init; _} as env)
      path ty lidx =
    match ty with
    | Q.TypeRecord Q.TyRow (fields , None) ->
        let buffer = Buffer.create 256 in
        let fmt = Format.formatter_of_buffer buffer in
        Format.fprintf fmt "CREATE TABLE IF NOT EXISTS %a("
          pp_table_name path;
        let rec aux_field fmt (s, ty) =
          Format.fprintf fmt "%a %a" pp_pgfield s (pp_type_as_pgtype ~path:(List.rev (s::path)) env) ty
        in
        let env = List.fold_left
          (fun env (field, ty) ->
             Format.fprintf fmt "%a, " aux_field (field, ty);
             env
          ) env fields
        in
        Format.pp_list ","
          (fun fmt idx ->
             Format.fprintf fmt " PRIMARY KEY(%a)"
               (Format.pp_list "," pp_pgfield) idx)
          fmt lidx;
        Format.fprintf fmt ")";
        Format.pp_print_flush fmt ();
        {env with tb_init = (Buffer.contents buffer)::tb_init}
    | Q.TypeRecord _ -> assert false
    | Q.TypeName _ ->
        table_from_ty env path (QmlTypesUtils.Inspect.follow_alias_noopt_private gamma ty) lidx
    | _ -> assert false

  let database env name =
    (* Create the default table *)
    let ({gamma; annotmap; ty_init; tb_init; q_prepared; d_prepared; u_prepared; _} as env) =
      let mty =
        StringListMap.fold
          (fun path ty acc ->
             let rec aux path (acc:[`sub of _ | `ty of _] StringMap.t)=
               match path with
               | [] -> acc
               | [t] -> StringMap.add t (`ty ty) acc
               | t::q ->
                   match StringMap.find_opt t (acc:[`sub of _ | `ty of _] StringMap.t) with
                   | None -> StringMap.add t (`sub (aux q StringMap.empty)) acc
                   | Some (`sub sub) -> StringMap.add t (`sub (aux q sub)) acc
                   | _ -> assert false
             in aux path acc)
          env.tb_default StringMap.empty
      in
      let mty = StringMap.add "_id" (`ty (Q.TypeConst Q.TyInt)) mty in
      let rec aux mty =
        let lty = StringMap.to_list mty in
        let lty = List.map
          (fun (f, x) -> f, (match x with | `ty ty -> ty | `sub mty -> aux mty))
          lty
        in
        Q.TypeRecord (Q.TyRow (lty, None))
      in
      let ty = aux mty in
      table_from_ty env ["_default"] ty [["_id"]]
    in
    let annotmap, open_ = OpaMapToIdent.typed_val ~label Api.Db.open_ annotmap gamma in
    let annotmap, name = C.string annotmap name in
    let annotmap, tables =
      List.fold_left
        (fun (annotmap, tables) table ->
           let annotmap, table = C.string annotmap table in
           annotmap, table::tables
        ) (annotmap, []) tb_init
    in
    let annotmap, tables =
      StringListMap.fold
        (fun _ kind (annotmap, tys) ->
           match kind with
           | `type_ (_, _, q) ->
               let annotmap, q = C.string annotmap q in
               annotmap, q::tys
           | _ -> (annotmap, tys)
        ) ty_init (annotmap, tables)
    in
    let annotmap, tables = C.list (annotmap, gamma) tables in
    let annotmap, statements =
      let annotmap, statements =
        let prepare_statement prepared (annotmap, init) =
          QueryMap.fold
            (fun _prepared (qid, query) (annotmap, statements) ->
               let annotmap, qid = C.string annotmap qid in
               let annotmap, query = C.string annotmap query in
               (* TODO: Optimized types *)
               let annotmap, types = C.list (annotmap, gamma) [] in
               let annotmap, statement =
                 C.record annotmap [
                   "id", qid;
                   "query", query;
                   "types", types;
                 ]
               in
               annotmap, statement::statements
          ) prepared (annotmap, init)
        in
        prepare_statement d_prepared (prepare_statement q_prepared (annotmap, []))
      in
      C.list (annotmap, gamma) statements
    in
    let annotmap, queries =
      let annotmap, queries =
        UpdateMap.fold
          (fun _ (_, query) (annotmap, queries) ->
             let annotmap, query = C.string annotmap query in
             annotmap, query::queries
          ) u_prepared (annotmap, [])
      in
      C.list (annotmap, gamma) queries
    in
    let annotmap, pgdb = C.apply gamma annotmap open_ [name; tables; statements; queries] in
    {env with annotmap}, pgdb

  let table_default env path ty =
    let env = type_from_ty env path [] ty in
    {env with tb_default = StringListMap.add path ty env.tb_default}

  let table env path ty lidx =
    table_from_ty (type_from_ty env path [] ty) path ty lidx

end

let process_path env code =
  let fmap tra env = function
    | Q.Path (label, path, kind, select) as expr ->
        (try
          let context = QmlError.Context.annoted_expr env.annotmap expr in
          let env, result =
            Generator.path ~context env (label, path, kind, select) in
          tra env result
        with e ->
          OManager.serror "Error while generating postgres path: %a\n" QmlPrint.pp#expr expr;
          raise e)
    | e -> tra env e
  in
  QmlAstWalk.CodeExpr.fold_map
    (fun env expr ->
       let env, expr = QmlAstWalk.Expr.traverse_foldmap fmap env expr in
       fmap (fun a e -> a,e) env expr)
    env code

let init_database env =
  List.fold_left
    (fun (env, newvals) database ->
       if database.S.options.QD.backend = `postgres
         && database.S.package = ObjectFiles.get_current_package_name () then
           let ident = database.S.ident in
           let name = database.S.name in
           let env, open_ = Generator.database env name in
           (env, (Q.NewVal (label, [ident, open_]))::newvals)
       else (env, newvals)
    )
    (env, []) (S.get_db_declaration env.schema)

let init_declaration ({gamma; schema; _} as env) code =
  List.fold_left_filter_map
    (fun env -> function
     | Q.Database _ -> env, None
     | Q.NewDbValue
         (_, (QD.Db_TypeDecl (p, _)
          | QD.Db_Default    (p, _)
          | QD.Db_Alias      (p, _)
          | QD.Db_Constraint (p, _)
          | QD.Db_Virtual    (p, _) as decl)) ->
         begin match p with
         | QD.Decl_fld k::_ ->
             if (S.get_node gamma schema [QD.FldKey k]).S.database.S.options.QD.backend
               <> `postgres then env, None
             else (
               match decl with
               | QD.Db_TypeDecl ((QD.Decl_fld _)::p, ty) ->
                   let rec aux rpath p = match p with
                     | (QD.Decl_set lidx)::[] ->
                         Generator.table env rpath ty lidx, None
                     | (QD.Decl_set _lidx)::_ -> assert false
                     | (QD.Decl_fld str)::p -> aux (str::rpath) p
                     | [] ->
                         Generator.table_default env (List.rev rpath) ty , None
                     | _ -> assert false
                   in aux [] p
               | _ -> env, None
             )
         | _ -> assert false
         end
     | x -> env, Some x) env  code

let process_code ~stdlib_gamma gamma annotmap schema code =
  match ObjectFiles.compilation_mode () with
  | `init -> (annotmap, code)
  | _ ->
      let gamma = QmlTypes.Env.unsafe_append stdlib_gamma gamma in
      let env = Generator.make_env gamma annotmap schema in
      let env, code = init_declaration env code in
      let env, code = process_path env code in
      let env, vals = init_database env in
      (env.annotmap, vals@code)


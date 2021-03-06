(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2017.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

(* Tezos Command line interface - Generic JSON RPC interface *)

open Lwt.Infix
open Cli_entries
open Json_schema

(*-- Assisted, schema directed input fill in --------------------------------*)

exception Unsupported_construct

type input = {
  int : int -> int -> string option -> string list -> int Lwt.t ;
  float : string option -> string list -> float Lwt.t ;
  string : string option -> string list -> string Lwt.t ;
  bool : string option -> string list -> bool Lwt.t ;
  continue : string option -> string list -> bool Lwt.t ;
  display : string -> unit Lwt.t ;
}

(* generic JSON generation from a schema with callback for random or
   interactive filling *)
let fill_in ?(show_optionals=true) input schema =
  let rec element path { title ; kind }=
    match kind with
    | Integer { minimum ; maximum } ->
        let minimum =
          match minimum with
          | None -> min_int
          | Some (m, `Inclusive) -> int_of_float m
          | Some (m, `Exclusive) -> int_of_float m + 1 in
        let maximum =
          match maximum with
          | None -> max_int
          | Some (m, `Inclusive) -> int_of_float m
          | Some (m, `Exclusive) -> int_of_float m - 1 in
        input.int minimum maximum title path >>= fun i ->
        Lwt.return (`Float (float i))
    | Number _ ->
        input.float title path >>= fun f ->
        Lwt.return (`Float f)
    | Boolean ->
        input.bool title path >>= fun f ->
        Lwt.return (`Bool f)
    | String _ ->
        input.string title path >>= fun f ->
        Lwt.return (`String f)
    | Combine ((One_of | Any_of), elts) ->
        let nb = List.length elts in
        input.int 0 (nb - 1) (Some "Select the schema to follow") path >>= fun n ->
        element path (List.nth elts n)
    | Combine ((All_of | Not), _) ->  Lwt.fail Unsupported_construct
    | Def_ref name ->
        Lwt.return (`String (Json_query.json_pointer_of_path name))
    | Id_ref _ | Ext_ref _ ->
        Lwt.fail Unsupported_construct
    | Array (elts, _) ->
        let rec fill_loop acc n ls =
          match ls with
          | [] -> Lwt.return acc
          | elt :: elts ->
              element (string_of_int n :: path) elt >>= fun json ->
              fill_loop (json :: acc) (succ n) elts
        in
        fill_loop [] 0 elts >>= fun acc ->
        Lwt.return (`A (List.rev acc))
    | Object { properties } ->
        let properties =
          if show_optionals
          then properties
          else (List.filter (fun (_, _, b, _) -> b) properties) in
        let rec fill_loop acc ls =
          match ls with
          | [] -> Lwt.return acc
          | (n, elt, _, _) :: elts ->
              element (n :: path) elt >>= fun json ->
              fill_loop ((n, json) :: acc) elts
        in
        fill_loop [] properties >>= fun acc ->
        Lwt.return (`O (List.rev acc))
    | Monomorphic_array (elt, specs) ->
        let rec fill_loop acc min n max =
          if n > max then
            Lwt.return acc
          else
            element (string_of_int n :: path) elt >>= fun json ->
            (if n < min then Lwt.return true else input.continue title path) >>= function
            | true -> fill_loop (json :: acc) min (succ n) max
            | false -> Lwt.return (json :: acc)
        in
        let max = match specs.max_items with None -> max_int | Some m -> m in
        fill_loop [] specs.min_items 0 max >>= fun acc ->
        Lwt.return (`A (List.rev acc))
    | Any -> Lwt.fail Unsupported_construct
    | Dummy -> Lwt.fail Unsupported_construct
    | Null -> Lwt.return `Null
  in
  element [] (Json_schema.root schema)

let random_fill_in ?(show_optionals=true) schema =
  let display _ = Lwt.return () in
  let int min max _ _ =
    let max = Int64.of_int max
    and min = Int64.of_int min in
    let range = Int64.sub max min in
    let random_int64 = Int64.add (Random.int64 range) min in
    Lwt.return (Int64.to_int random_int64) in
  let string _title _ = Lwt.return "" in
  let float _ _ = Lwt.return (Random.float infinity) in
  let bool _ _ = Lwt.return (Random.int 2 = 0) in
  let continue _ _ = Lwt.return (Random.int 4 = 0) in
  Lwt.catch
    (fun () ->
       fill_in ~show_optionals
         { int ; float ; string ; bool ; display ; continue }
         schema >>= fun json ->
       Lwt.return (Ok json))
    (fun e ->
       let msg = Printf.sprintf "Fill-in failed %s\n%!" (Printexc.to_string e) in
       Lwt.return (Error msg))

let editor_fill_in ?(show_optionals=true) schema =
  let tmp = Filename.temp_file "tezos_rpc_call_" ".json" in
  let rec init () =
    (* write a temp file with instructions *)
    random_fill_in ~show_optionals schema >>= function
    | Error msg -> Lwt.return (Error msg)
    | Ok json ->
        Lwt_io.(with_file ~mode:Output tmp (fun fp ->
            write_line fp (Data_encoding_ezjsonm.to_string json))) >>= fun () ->
        edit ()
  and edit () =
    (* launch the user's editor on it *)
    let editor_cmd =
      try let ed = Sys.getenv "EDITOR" in Lwt_process.shell (ed ^ " " ^ tmp)
      with Not_found ->
      try let ed = Sys.getenv "VISUAL" in Lwt_process.shell (ed ^ " " ^ tmp)
      with Not_found ->
        if Sys.win32 then
          (* TODO: I have no idea what I'm doing here *)
          ("", [| "notepad.exe" ; tmp |])
        else
          (* TODO: vi on MacOSX ? *)
          ("", [| "nano" ; tmp |])
    in
    (Lwt_process.open_process_none editor_cmd) # status >>= function
    | Unix.WEXITED 0 ->
        reread () >>= fun json ->
        delete () >>= fun () ->
        Lwt.return json
    | Unix.WSIGNALED x | Unix.WSTOPPED x | Unix.WEXITED x ->
        let msg = Printf.sprintf "FAILED %d \n%!" x in
        delete () >>= fun () ->
        Lwt.return (Error msg)
  and reread () =
    (* finally reread the file *)
    Lwt_io.(with_file ~mode:Input tmp (fun fp -> read fp)) >>= fun text ->
    match Data_encoding_ezjsonm.from_string text with
    | Ok r -> Lwt.return (Ok r)
    | Error msg -> Lwt.return (Error (Printf.sprintf "bad input: %s" msg))
  and delete () =
    (* and delete the temp file *)
    Lwt_unix.unlink tmp
  in
  init ()

(*-- Nice list display ------------------------------------------------------*)

let rec count =
  let open RPC_description in
  function
  | Empty -> 0
  | Dynamic _ -> 1
  | Static { services ; subdirs } ->
      let service = RPC_service.MethMap.cardinal services in
      let subdirs =
        match subdirs with
        | None -> 0
        | Some (Suffixes subdirs) ->
            Resto.StringMap.fold (fun _ t r -> r + count t) subdirs 0
        | Some (Arg (_, subdir)) -> count subdir in
      service + subdirs

(*-- Commands ---------------------------------------------------------------*)

let list url (cctxt : Client_commands.full_context) =
  let args = String.split '/' url in
  Client_node_rpcs.describe cctxt
    ~recurse:true args >>=? fun tree ->
  let open RPC_description in
  let collected_args = ref [] in
  let collect arg =
    if not (arg.RPC_arg.descr <> None && List.mem arg !collected_args) then
      collected_args := arg :: !collected_args in
  let display_paragraph ppf description =
    Format.fprintf ppf "@,    @[%a@]"
      (fun ppf words -> List.iter (Format.fprintf ppf "%s@ ") words)
      (String.split ' ' description)
  in
  let display_arg ppf arg =
    match arg.RPC_arg.descr with
    | None -> Format.fprintf ppf "%s" arg.RPC_arg.name
    | Some descr ->
        Format.fprintf ppf "<%s>%a" arg.RPC_arg.name display_paragraph descr
  in
  let display_service ppf (_path, tpath, service) =
    Format.fprintf ppf "- %s /%s"
      (RPC_service.string_of_meth service.meth)
      (String.concat "/" tpath) ;
    match service.description with
    | None | Some "" -> ()
    | Some description -> display_paragraph ppf description
  in
  let display_services ppf (_path, tpath, services) =
    Format.pp_print_list
      (fun ppf (_,s) -> display_service ppf (_path, tpath, s))
      ppf
      (RPC_service.MethMap.bindings services)
  in
  let rec display ppf (path, tpath, tree) =
    match tree with
    | Dynamic description -> begin
        Format.fprintf ppf "- /%s <dynamic>" (String.concat "/" tpath) ;
        match description with
        | None | Some "" -> ()
        | Some description -> display_paragraph ppf description
      end
    | Empty -> ()
    | Static { services ; subdirs = None } ->
        display_services ppf (path, tpath, services)
    | Static { services ; subdirs = Some (Suffixes subdirs) } -> begin
        match RPC_service.MethMap.cardinal services, Resto.StringMap.bindings subdirs with
        | 0, [] -> ()
        | 0, [ n, solo ] ->
            display ppf (path @ [ n ], tpath @ [ n ], solo)
        | _, items when count tree >= 3 && path <> [] ->
            Format.fprintf ppf "@[<v 2>+ %s/@,%a@]"
              (String.concat "/" path) (display_list tpath) items
        | _, items when count tree >= 3 && path <> [] ->
            Format.fprintf ppf "@[<v 2>+ %s@,%a@,%a@]"
              (String.concat "/" path)
              display_services (path, tpath, services)
              (display_list tpath) items
        | 0, (n, t) :: items ->
            Format.fprintf ppf "%a"
              display (path @ [ n ], tpath @ [ n ], t) ;
            List.iter
              (fun (n, t) ->
                 Format.fprintf ppf "@,%a"
                   display (path @ [ n ], tpath @ [ n ], t))
              items
        | _, items ->
            display_services ppf (path, tpath, services) ;
            List.iter
              (fun (n, t) ->
                 Format.fprintf ppf "@,%a"
                   display (path @ [ n ], tpath @ [ n ], t))
              items
      end
    | Static { services ; subdirs = Some (Arg (arg, solo)) }
      when RPC_service.MethMap.cardinal services = 0 ->
        collect arg ;
        let name = Printf.sprintf "<%s>" arg.RPC_arg.name in
        display ppf (path @ [ name ], tpath @ [ name ], solo)
    | Static { services;
               subdirs = Some (Arg (arg, solo)) } ->
        collect arg ;
        display_services ppf (path, tpath, services) ;
        Format.fprintf ppf "@," ;
        let name = Printf.sprintf "<%s>" arg.RPC_arg.name in
        display ppf (path @ [ name ], tpath @ [ name ], solo)
  and display_list tpath =
    Format.pp_print_list
      (fun ppf (n,t) -> display ppf ([ n ], tpath @ [ n ], t))
  in
  cctxt#message "@ @[<v 2>Available services:@ @ %a@]@."
    display (args, args, tree) >>= fun () ->
  if !collected_args <> [] then begin
    cctxt#message "@,@[<v 2>Dynamic parameter description:@ @ %a@]@."
      (Format.pp_print_list display_arg) !collected_args >>= fun () ->
    return ()
  end else return ()


let schema url (cctxt : Client_commands.full_context) =
  let args = String.split '/' url in
  let open RPC_description in
  Client_node_rpcs.describe cctxt ~recurse:false args >>=? function
  | Static { services } -> begin
      match RPC_service.MethMap.find `POST services with
      | exception Not_found ->
          cctxt#message
            "No service found at this URL (but this is a valid prefix)\n%!" >>= fun () ->
          return ()
      | { input = Some input ; output } ->
          let json = `O [ "input", Json_schema.to_json input ;
                          "output", Json_schema.to_json output ] in
          cctxt#message "%a" Json_repr.(pp (module Ezjsonm)) json >>= fun () ->
          return ()
      | { input = None ; output } ->
          let json = `O [ "output", Json_schema.to_json output ] in
          cctxt#message "%a" Json_repr.(pp (module Ezjsonm)) json >>= fun () ->
          return ()
    end
  | _ ->
      cctxt#message
        "No service found at this URL (but this is a valid prefix)\n%!" >>= fun () ->
      return ()

let format url (cctxt : #Client_commands.logging_rpcs) =
  let args = String.split '/' url in
  let open RPC_description in
  Client_node_rpcs.describe cctxt ~recurse:false args >>=? function
  | Static { services } -> begin
      match RPC_service.MethMap.find `POST services with
      | exception Not_found ->
          cctxt#message
            "No service found at this URL (but this is a valid prefix)\n%!" >>= fun () ->
          return ()
      | { input = Some input ; output } ->
          cctxt#message
            "@[<v 0>\
             @[<v 2>Input format:@,%a@]@,\
             @[<v 2>Output format:@,%a@]@,\
             @]"
            Json_schema.pp input
            Json_schema.pp output >>= fun () ->
          return ()
      | { input = None ; output } ->
          cctxt#message
            "@[<v 0>\
             @[<v 2>Output format:@,%a@]@,\
             @]"
            Json_schema.pp output >>= fun () ->
          return ()
    end
  | _ ->
      cctxt#message
        "No service found at this URL (but this is a valid prefix)\n%!" >>= fun () ->
      return ()

let fill_in ?(show_optionals=true) schema =
  let open Json_schema in
  match (root schema).kind with
  | Null -> Lwt.return (Ok `Null)
  | Any | Object { properties = [] } -> Lwt.return (Ok (`O []))
  | _ -> editor_fill_in ~show_optionals schema

let display_answer (cctxt : #Client_commands.full_context) = function
  | `Ok json ->
      cctxt#message "%a"
        Json_repr.(pp (module Ezjsonm)) json >>= fun () ->
      return ()
  | `Not_found _ ->
      cctxt#message "No service found at this URL\n%!" >>= fun () ->
      return ()
  | `Unauthorized _ | `Error _ | `Forbidden _ | `Conflict _ ->
      cctxt#message "Unexpected server answer\n%!" >>= fun () ->
      return ()

let call raw_url (cctxt : #Client_commands.full_context) =
  let uri = Uri.of_string raw_url in
  let args = String.split_path (Uri.path uri) in
  Client_node_rpcs.describe cctxt ~recurse:false args >>=? function
  | Static { services } -> begin
      match RPC_service.MethMap.find `POST services with
      | exception Not_found ->
          cctxt#message
            "No service found at this URL (but this is a valid prefix)\n%!" >>= fun () ->
          return ()
      | { input = None } ->
          cctxt#generic_json_call `POST uri >>=?
          display_answer cctxt
      | { input = Some input } ->
          fill_in ~show_optionals:false input >>= function
          | Error msg ->
              cctxt#error "%s" msg >>= fun () ->
              return ()
          | Ok json ->
              cctxt#generic_json_call `POST ~body:json uri >>=?
              display_answer cctxt
    end
  | _ ->
      cctxt#message "No service found at this URL\n%!" >>= fun () ->
      return ()

let call_with_json raw_url json (cctxt: Client_commands.full_context) =
  let uri = Uri.of_string raw_url in
  match Data_encoding_ezjsonm.from_string json with
  | Error err ->
      cctxt#error
        "Failed to parse the provided json: %s\n%!"
        err
  | Ok body ->
      cctxt#generic_json_call `POST ~body uri >>=?
      display_answer cctxt

let call_with_file_or_json url maybe_file (cctxt: Client_commands.full_context) =
  begin
    match TzString.split ':' ~limit:1 maybe_file with
    | [ "file" ; filename] ->
        (* Mostly copied from src/client/client_aliases.ml *)
        Lwt.catch
          (fun () ->
             Lwt_io.(with_file ~mode:Input filename read) >>= fun content ->
             return content)
          (fun exn ->
             failwith
               "cannot read file (%s)" (Printexc.to_string exn))
    | _ -> return maybe_file
  end >>=? fun json ->
  call_with_json url json cctxt

let group =
  { Cli_entries.name = "rpc" ;
    title = "Commands for the low level RPC layer" }

let commands = [

  command ~desc: "list all understood protocol versions"
    no_options
    (fixed [ "list" ; "versions" ])
    (fun () (cctxt : Client_commands.full_context) ->
       Lwt_list.iter_s
         (fun (ver, _) -> cctxt#message "%a" Protocol_hash.pp_short ver)
         (Client_commands.get_versions ()) >>= fun () ->
       return ()) ;

  command ~group ~desc: "list available RPCs (low level command for advanced users)"
    no_options
    (prefixes [ "rpc" ; "list" ] @@ stop)
    (fun () -> (list "/"));

  command ~group ~desc: "list available RPCs (low level command for advanced users)"
    no_options
    (prefixes [ "rpc" ; "list" ] @@ string ~name:"url" ~desc: "the RPC's prefix to be described" @@ stop)
    (fun () -> list) ;

  command ~group ~desc: "get the input and output JSON schemas of an RPC"
    no_options
    (prefixes [ "rpc" ; "schema" ] @@ string ~name: "url" ~desc: "the RPC's URL" @@ stop)
    (fun () -> schema) ;

  command ~group ~desc: "get the humanoid readable input and output formats of an RPC"
    no_options
    (prefixes [ "rpc" ; "format" ] @@ string ~name: "url" ~desc: "the RPC's URL" @@ stop)
    (fun () -> format) ;

  command ~group ~desc: "call an RPC (low level command for advanced users)"
    no_options
    (prefixes [ "rpc" ; "call" ] @@ string ~name: "url" ~desc: "the RPC's URL" @@ stop)
    (fun () -> call) ;

  command ~group ~desc: "call an RPC (low level command for advanced users)"
    no_options
    (prefixes [ "rpc" ; "call" ] @@ string ~name: "url" ~desc: "the RPC's URL"
     @@ prefix "with"
     @@ string ~name:"input"
       ~desc:"the JSON input to the RPC or `file:FILENAME`, which is the path to a file containing the JSON"
     @@ stop)
    (fun () -> call_with_file_or_json)

]

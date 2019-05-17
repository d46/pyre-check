(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core

module ServerDependencies = Dependencies
open Ast
open Analysis
open Network

open State
open Configuration.Analysis
open Configuration.Server
open Protocol
open Request

open Pyre


exception IncorrectParameters of Type.t


let parse_lsp ~configuration ~request =
  let open LanguageServer.Types in
  let log_method_error method_name =
    Log.error
      "Error for method %s: %s does not have required parameters"
      method_name
      (Yojson.Safe.pretty_to_string request)
  in
  let uri_to_path ~uri =
    let search_path = Configuration.Analysis.search_path configuration in
    Path.from_uri uri
    >>= fun path ->
    match Path.search_for_path ~search_path ~path with
    | Some path ->
        Some path
    | None ->
        Ast.SharedMemory.SymlinksToPaths.get (Path.absolute path)
        >>= fun path -> Path.search_for_path ~search_path ~path
  in
  let string_path_to_file string_path =
    File.create (Path.create_absolute ~follow_symbolic_links:false string_path)
  in
  let process_request request_method =
    match request_method with
    | "textDocument/definition" ->
        begin
          match TextDocumentDefinitionRequest.of_yojson request with
          | Ok {
              TextDocumentDefinitionRequest.parameters = Some {
                  TextDocumentPositionParameters.textDocument = {
                    TextDocumentIdentifier.uri;
                    _;
                  };
                  position = { Position.line; character };
                };
              id;
              _;
            } ->
              uri_to_path ~uri
              >>| File.create
              >>| fun file ->
              GetDefinitionRequest {
                DefinitionRequest.id;
                file;
                (* The LSP protocol starts a file at line 0, column 0.
                   Pyre starts a file at line 1, column 0. *)
                position = { Ast.Location.line = line + 1; column = character };
              }
          | Ok _ ->
              None
          | Error yojson_error ->
              Log.dump "%s" yojson_error;
              None
        end
    | "textDocument/didClose" ->
        begin
          match DidCloseTextDocument.of_yojson request with
          | Ok {
              DidCloseTextDocument.parameters = Some {
                  DidCloseTextDocumentParameters.textDocument = {
                    TextDocumentIdentifier.uri;
                    _;
                  };
                  _
                };
              _;
            } ->
              uri_to_path ~uri
              >>| File.create
              >>| fun file ->
              Log.log ~section:`Server "Closed file %a" File.pp file;
              CloseDocument file
          | Ok _ ->
              log_method_error request_method;
              None
          | Error yojson_error ->
              Log.log ~section:`Server "Error: %s" yojson_error;
              None
        end

    | "textDocument/didOpen" ->
        begin
          match DidOpenTextDocument.of_yojson request with
          | Ok {
              DidOpenTextDocument.parameters = Some {
                  DidOpenTextDocumentParameters.textDocument = {
                    TextDocumentItem.uri;
                    _;
                  };
                  _;
                };
              _;
            } ->
              uri_to_path ~uri
              >>| File.create
              >>| fun file ->
              Log.log ~section:`Server "Opened file %a" File.pp file;
              OpenDocument file
          | Ok _ ->
              log_method_error request_method;
              None
          | Error yojson_error ->
              Log.log ~section:`Server "Error: %s" yojson_error;
              None
        end

    | "textDocument/didSave" ->
        begin
          match DidSaveTextDocument.of_yojson request with
          | Ok {
              DidSaveTextDocument.parameters = Some {
                  DidSaveTextDocumentParameters.textDocument = {
                    TextDocumentIdentifier.uri;
                    _;
                  };
                  text;
                };
              _;
            } ->
              uri_to_path ~uri
              >>| File.create ?content:text
              >>| fun file ->
              SaveDocument file
          | Ok _ ->
              log_method_error request_method;
              None
          | Error yojson_error ->
              Log.log ~section:`Server "Error: %s" yojson_error;
              None
        end

    | "textDocument/hover" ->
        begin
          match HoverRequest.of_yojson request with
          | Ok {
              HoverRequest.parameters = Some {
                  TextDocumentPositionParameters.textDocument = {
                    TextDocumentIdentifier.uri;
                    _;
                  };
                  position = { Position.line; character };
                };
              id;
              _;
            } ->
              uri_to_path ~uri
              >>| File.create
              >>| fun file ->
              HoverRequest {
                DefinitionRequest.id;
                file;
                (* The LSP protocol starts a file at line 0, column 0.
                   Pyre starts a file at line 1, column 0. *)
                position = { Ast.Location.line = line + 1; column = character };
              }
          | Ok _ ->
              None
          | Error yojson_error ->
              Log.log ~section:`Server "Error: %s" yojson_error;
              None
        end
    | "textDocument/codeAction" ->
        begin
          match CodeActionRequest.of_yojson request with
          | Ok {
              CodeActionRequest.parameters = Some {
                  CodeActionParameters.textDocument = {
                    TextDocumentIdentifier.uri;
                    _;
                  };
                  _;
                };
              _;
            } ->
              uri_to_path ~uri
              >>| File.create
              >>| fun file ->
              CodeActionRequest file
          | Ok _ ->
              None
          | Error yojson_error ->
              Log.log ~section:`Server "Error: %s" yojson_error;
              None
        end

    | "updateFiles" ->
        begin
          match UpdateFiles.of_yojson request with
          | Ok {
              UpdateFiles.parameters = Some {
                  files;
                  _
                };
              _
            } ->
              let files = List.map files ~f:string_path_to_file in
              Some (TypeCheckRequest files)
          | Ok _ ->
              None
          | Error yojson_error ->
              Log.log ~section:`Server "Error: %s" yojson_error;
              None
        end
    | "displayTypeErrors" ->
        begin
          match LanguageServer.Types.DisplayTypeErrors.of_yojson request with
          | Ok {
              LanguageServer.Types.DisplayTypeErrors.parameters = Some {
                  files;
                  flush;
                  _
                };
              _
            } ->
              let files = List.map files ~f:string_path_to_file in
              Some (DisplayTypeErrors { files; flush })
          | Ok _ ->
              None
          | Error yojson_error ->
              Log.log ~section:`Server "Error: %s" yojson_error; None
        end

    | "shutdown" ->
        begin
          match ShutdownRequest.of_yojson request with
          | Ok { ShutdownRequest.id; _ } -> Some (ClientShutdownRequest id)
          | Error yojson_error -> Log.log ~section:`Server "Error: %s" yojson_error; None
        end

    | "exit" -> Some (ClientExitRequest Persistent)
    | "telemetry/rage" ->
        begin
          match RageRequest.of_yojson request with
          | Ok { RageRequest.id; _ } -> Some (Request.RageRequest id)
          | Error yojson_error -> Log.log ~section:`Server "Error: %s" yojson_error; None
        end
    | unmatched_method ->
        Log.log ~section:`Server "Unhandled %s" unmatched_method; None
  in
  try
    let request_method = Yojson.Safe.Util.member "method" request in
    process_request (Yojson.Safe.Util.to_string request_method)
  with Yojson.Safe.Util.Type_error _ -> None


type response = {
  state: State.t;
  response: Protocol.response option;
}


module LookupCache = struct
  let handle ~configuration file =
    try
      File.handle ~configuration file
      |> Option.some
    with File.NonexistentHandle error ->
      Log.info "%s" error;
      None


  let get_by_handle ~state:{ lookups; environment; _ } ~file ~handle =
    let cache_read = String.Table.find lookups (File.Handle.show handle) in
    match cache_read with
    | Some _ ->
        cache_read
    | None ->
        let lookup =
          let content =
            File.content file
            |> Option.value ~default:""
          in
          Ast.SharedMemory.Sources.get handle
          >>| Lookup.create_of_source environment
          >>| fun table -> { table; source = content }
        in
        lookup
        >>| (fun lookup -> String.Table.set lookups ~key:(File.Handle.show handle) ~data:lookup)
        |> ignore;
        lookup


  let evict ~state:{ lookups; _ } ~configuration file =
    handle ~configuration file
    >>| File.Handle.show
    >>| String.Table.remove lookups
    |> ignore


  let log_lookup ~handle ~position ~timer ~name ?(integers = []) ?(normals = []) () =
    let normals =
      let base_normals = [
        "handle", File.Handle.show handle;
        "position", Location.show_position position;
      ]
      in
      base_normals @ normals
    in
    Statistics.performance
      ~section:`Event
      ~category:"perfpipe_pyre_ide_integration"
      ~name
      ~timer
      ~integers
      ~normals
      ()


  let find_annotation ~state ~configuration ~file ~position =
    let find_annotation_by_handle handle =
      let timer = Timer.start () in
      let annotation =
        get_by_handle ~state ~file ~handle
        >>= fun { table; source } ->
        Lookup.get_annotation table ~position ~source
      in
      let normals =
        annotation
        >>| fun (location, annotation) ->
        [
          "resolved location", Location.Instantiated.show location;
          "resolved annotation", Type.show annotation;
        ]
      in
      log_lookup
        ~handle
        ~position
        ~timer
        ~name:"find annotation"
        ?normals
        ();
      annotation
    in
    handle ~configuration file
    >>= find_annotation_by_handle


  let find_all_annotations ~state ~configuration ~file =
    let find_annotation_by_handle handle =
      let timer = Timer.start () in
      let annotations =
        get_by_handle ~state ~file ~handle
        >>| (fun { table; _ } -> Lookup.get_all_annotations table)
        |> Option.value ~default:[]
      in
      let integers = ["annotation list size", List.length annotations] in
      log_lookup
        ~handle
        ~position:Location.any_position
        ~timer
        ~name:"find all annotations"
        ~integers
        ();
      annotations
    in
    handle ~configuration file
    >>| find_annotation_by_handle


  let find_definition ~state ~configuration file position =
    let find_definition_by_handle handle =
      let timer = Timer.start () in
      let definition =
        get_by_handle ~state ~file ~handle
        >>= fun { table; source } ->
        Lookup.get_definition table ~position ~source
      in
      let normals =
        definition
        >>| fun location -> ["resolved location", Location.Instantiated.show location]
      in
      log_lookup
        ~handle
        ~position
        ~timer
        ~name:"find definition"
        ?normals
        ();
      definition
    in
    handle ~configuration file
    >>= find_definition_by_handle
end


let process_client_shutdown_request ~state ~id =
  let open LanguageServer.Protocol in
  let response =
    ShutdownResponse.default id
    |> ShutdownResponse.to_yojson
    |> Yojson.Safe.to_string
  in
  { state; response = Some (LanguageServerProtocolResponse response) }


let process_type_query_request ~state:({ State.environment; _ } as state) ~configuration ~request =
  let (module Handler: Environment.Handler) = environment in
  let process_request () =
    let order = (module Handler.TypeOrderHandler : TypeOrder.Handler) in
    let resolution = TypeCheck.resolution environment () in
    let parse_and_validate expression =
      let annotation =
        (* Return untracked so we can specifically message the user about them. *)
        Resolution.parse_annotation
          ~allow_untracked:true
          ~allow_invalid_type_parameters:true
          resolution
          expression
      in
      if TypeOrder.is_instantiated order annotation then
        let mismatches, _ = Resolution.check_invalid_type_parameters resolution annotation in
        if List.is_empty mismatches then
          annotation
        else
          raise (IncorrectParameters annotation)
      else
        raise (TypeOrder.Untracked annotation)
    in
    match request with
    | TypeQuery.Attributes annotation ->
        let to_attribute {
            Node.value = { Annotated.Class.Attribute.name; annotation; _ };
            _;
          } =
          let annotation = Annotation.annotation annotation in
          {
            TypeQuery.name;
            annotation;
          }
        in
        parse_and_validate (Reference.expression annotation)
        |> Type.primitive_name
        >>= Handler.class_definition
        >>| Annotated.Class.create
        >>| (fun annotated_class -> Annotated.Class.attributes ~resolution annotated_class)
        >>| List.map ~f:to_attribute
        >>| (fun attributes -> TypeQuery.Response (TypeQuery.FoundAttributes attributes))

        |> Option.value
          ~default:(
            TypeQuery.Error (
              Format.sprintf
                "No class definition found for %s"
                (Reference.show annotation)))

    | TypeQuery.ComputeHashesToKeys ->
        let open Service.EnvironmentSharedMemory in
        (* Type order. *)
        let extend_map map ~new_map =
          Map.merge_skewed map new_map ~combine:(fun ~key:_ value _ -> value)
        in
        let map =
          let map =
            Map.set
              String.Map.empty
              ~key:(OrderKeys.hash_of_key SharedMemory.SingletonKey.key)
              ~data:(OrderKeys.serialize_key SharedMemory.SingletonKey.key)
          in
          match OrderKeys.get SharedMemory.SingletonKey.key with
          | Some indices ->
              let annotations = List.filter_map indices ~f:OrderAnnotations.get in
              extend_map
                map
                ~new_map:(Service.TypeOrder.compute_hashes_to_keys ~indices ~annotations)
          | None ->
              map
        in
        let handles =
          Ast.SharedMemory.HandleKeys.get ()
          |> File.Handle.Set.Tree.to_list
        in
        (* AST shared memory. *)
        let map =
          map
          |> extend_map ~new_map:(Ast.SharedMemory.HandleKeys.compute_hashes_to_keys ())
          |> extend_map
            ~new_map:(
              Ast.SharedMemory.SymlinksToPaths.compute_hashes_to_keys
                ~keys:(List.map handles ~f:File.Handle.show))
          |> extend_map ~new_map:(Ast.SharedMemory.Sources.compute_hashes_to_keys ~keys:handles)
          |> extend_map
            ~new_map:(
              Ast.SharedMemory.Modules.compute_hashes_to_keys
                ~keys:(List.map ~f:(fun handle -> Ast.Source.qualifier ~handle) handles))
          |> extend_map
            ~new_map:(
              Ast.SharedMemory.Handles.compute_hashes_to_keys
                ~keys:(List.map ~f:File.Handle.show handles))
        in
        (* Handle-based keys. *)
        let map =
          map
          |> extend_map ~new_map:(FunctionKeys.compute_hashes_to_keys ~keys:handles)
          |> extend_map ~new_map:(ClassKeys.compute_hashes_to_keys ~keys:handles)
          |> extend_map ~new_map:(GlobalKeys.compute_hashes_to_keys ~keys:handles)
          |> extend_map ~new_map:(AliasKeys.compute_hashes_to_keys ~keys:handles)
          |> extend_map ~new_map:(DependentKeys.compute_hashes_to_keys ~keys:handles)
        in
        (* Class definitions. *)
        let map =
          let keys =
            List.filter_map handles ~f:ClassKeys.get
            |> List.concat
          in
          extend_map map ~new_map:(ClassDefinitions.compute_hashes_to_keys ~keys)
          |> extend_map ~new_map:(ClassMetadata.compute_hashes_to_keys ~keys)
        in
        (* Aliases. *)
        let map =
          let keys =
            List.filter_map handles ~f:AliasKeys.get
            |> List.concat
          in
          extend_map map ~new_map:(Aliases.compute_hashes_to_keys ~keys)
        in
        (* Globals and undecorated functions. *)
        let map =
          let keys =
            List.filter_map handles ~f:GlobalKeys.get
            |> List.concat
          in
          extend_map map ~new_map:(Globals.compute_hashes_to_keys ~keys)
          |> extend_map ~new_map:(UndecoratedFunctions.compute_hashes_to_keys ~keys)
        in
        (* Dependents. *)
        let map =
          let keys =
            List.filter_map handles ~f:DependentKeys.get
            |> List.concat
          in
          extend_map map ~new_map:(Dependents.compute_hashes_to_keys ~keys)
        in
        (* Resolution shared memory. *)
        let map =
          let keys = ResolutionSharedMemory.get_keys ~handles in
          map
          |> extend_map ~new_map:(ResolutionSharedMemory.compute_hashes_to_keys ~keys)
          |> extend_map ~new_map:(ResolutionSharedMemory.Keys.compute_hashes_to_keys ~keys:handles)
        in
        (* Coverage. *)
        let map =
          extend_map map ~new_map:(Coverage.SharedMemory.compute_hashes_to_keys ~keys:handles)
        in
        map
        |> Map.to_alist
        |> List.sort ~compare:(fun (left, _) (right, _) -> String.compare left right)
        |> List.map ~f:(fun (hash, key) -> { TypeQuery.hash; key })
        |> fun response -> TypeQuery.Response (TypeQuery.FoundKeyMapping response)

    | TypeQuery.DecodeOcamlValues values ->
        let open Service.EnvironmentSharedMemory in
        let decode key value =
          let key, value = Base64.decode key, Base64.decode value in
          match key, value with
          | Ok key, Ok value ->
              begin
                match Memory.decode ~key ~value with
                | Ok decoded ->
                    Some decoded
                | _ ->
                    None
              end
          | _ ->
              None
        in
        let serialize_decoded decoded =
          let decode index =
            let annotation =
              Handler.TypeOrderHandler.find
                (Handler.TypeOrderHandler.annotations ())
                index
            in
            match annotation with
            | None ->
                Format.sprintf "Undecodable(%d)" index
            | Some annotation ->
                Type.show annotation
          in
          let decode_target { TypeOrder.Target.target; parameters } =
            Format.sprintf
              "%s[%s]"
              (decode target)
              (List.map parameters ~f:Type.show
               |> String.concat ~sep:", ")
          in
          match decoded with
          | (ClassDefinitions.Decoded (key, value)) ->
              let value =
                match value with
                | Some { Node.value = definition; _ } ->
                    `Assoc [
                      "class_definition", `String (Ast.Statement.Class.show definition);
                    ]
                    |> Yojson.to_string
                    |> Option.some
                | None ->
                    None
              in
              Some (ClassValue.description, key, value)
          | (ClassMetadata.Decoded (key, value)) ->
              let value =
                match value with
                | Some { Resolution.successors; is_test; is_final; } ->
                    `Assoc [
                      "successors",
                      `String (List.to_string ~f:Type.show_primitive successors);
                      "is_test",
                      `Bool is_test;
                      "is_final",
                      `Bool is_final;
                    ]
                    |> Yojson.to_string
                    |> Option.some
                | None ->
                    None
              in
              Some (ClassMetadataValue.description, key, value)
          | (Aliases.Decoded (key, value)) ->
              Some (AliasValue.description, key, value >>| Type.show)
          | (Globals.Decoded (key, value)) ->
              let value =
                value
                >>| Node.value
                >>| Annotation.sexp_of_t
                >>| Sexp.to_string
              in
              Some (GlobalValue.description, Reference.show key, value)
          | (UndecoratedFunctions.Decoded (key, value)) ->
              Some (
                UndecoratedFunctionValue.description,
                Reference.show key,
                value
                >>| Type.Callable.show_overload Type.pp
              )
          | (Dependents.Decoded (key, value)) ->
              Some (
                DependentValue.description,
                Reference.show key,
                value
                >>| Reference.Set.Tree.to_list
                >>| List.to_string ~f:Reference.show
              )
          | (FunctionKeys.Decoded (key, value)) ->
              Some (
                FunctionKeyValue.description,
                File.Handle.show key,
                value
                >>| List.to_string ~f:Reference.show
              )

          | (ClassKeys.Decoded (key, value)) ->
              Some (
                ClassKeyValue.description,
                File.Handle.show key,
                value
                >>| List.to_string ~f:Fn.id
              )
          | (GlobalKeys.Decoded (key, value)) ->
              Some (
                GlobalKeyValue.description,
                File.Handle.show key,
                value
                >>| List.to_string ~f:Reference.show
              )
          | (AliasKeys.Decoded (key, value)) ->
              Some (
                AliasKeyValue.description,
                File.Handle.show key,
                value
                >>| List.to_string ~f:ident
              )
          | (DependentKeys.Decoded (key, value)) ->
              Some (
                DependentKeyValue.description,
                File.Handle.show key,
                value
                >>| List.to_string ~f:Reference.show
              )
          | (OrderIndices.Decoded (key, value)) ->
              Some (
                OrderIndexValue.description,
                key,
                value
                >>| Int.to_string
              )
          | (OrderAnnotations.Decoded (key, value)) ->
              Some (
                OrderAnnotationValue.description,
                Int.to_string key,
                value
                >>| Type.show
              )
          | (OrderEdges.Decoded (key, value)) ->
              Some (
                EdgeValue.description,
                decode key,
                value
                >>| List.to_string ~f:decode_target
              )
          | (OrderBackedges.Decoded (key, value)) ->
              Some (
                BackedgeValue.description,
                decode key,
                value
                >>| List.to_string ~f:decode_target
              )
          | (OrderKeys.Decoded (key, value)) ->
              Some (
                OrderKeyValue.description,
                Int.to_string key,
                value
                >>| List.to_string ~f:decode
              )
          | (Ast.SharedMemory.SymlinksToPaths.SymlinksToPaths.Decoded (key, value)) ->
              Some (
                Ast.SharedMemory.SymlinksToPaths.SymlinkSource.description,
                key,
                value >>| Path.show
              )
          | (Ast.SharedMemory.Sources.Sources.Decoded (key, value)) ->
              Some (
                Ast.SharedMemory.Sources.SourceValue.description,
                File.Handle.show key,
                value >>| Source.show
              )
          | (Ast.SharedMemory.Sources.QualifiersToHandles.Decoded (key, value)) ->
              Some (
                Ast.SharedMemory.Sources.HandleValue.description,
                Reference.show key,
                value >>| File.Handle.show
              )
          | (Ast.SharedMemory.HandleKeys.HandleKeys.Decoded (key, value)) ->
              Some (
                Ast.SharedMemory.HandleKeys.HandleKeysValue.description,
                Int.to_string key,
                value
                >>| File.Handle.Set.Tree.sexp_of_t
                >>| Sexp.to_string
              )
          | (Ast.SharedMemory.Modules.Modules.Decoded (key, value)) ->
              Some (
                Ast.SharedMemory.Modules.ModuleValue.description,
                Reference.show key,
                value
                >>| Module.sexp_of_t
                >>| Sexp.to_string
              )
          | (Ast.SharedMemory.Handles.Paths.Decoded (key, value)) ->
              Some (
                Ast.SharedMemory.Handles.PathValue.description,
                Int.to_string key,
                value
              )
          | (Coverage.SharedMemory.Decoded (key, value)) ->
              Some (
                Coverage.CoverageValue.description,
                File.Handle.show key,
                value
                >>| Coverage.show
              )
          | (ResolutionSharedMemory.Decoded (key, value)) ->
              Some (
                ResolutionSharedMemory.TypeAnnotationsValue.description,
                Reference.show key,
                value
                >>| ResolutionSharedMemory.show_annotations
              )
          | _ ->
              None
        in
        let build_response { TypeQuery.decoded; undecodable_keys } = function
          | TypeQuery.SerializedValue { serialized_key; serialized_value } ->
              begin
                let serialized =
                  decode serialized_key serialized_value
                  >>= serialize_decoded
                in
                match serialized with
                | Some (kind, key, value) ->
                    let decoded_value =
                      TypeQuery.DecodedValue {
                        serialized_key;
                        kind;
                        actual_key = key;
                        actual_value = value;
                      }
                    in
                    { TypeQuery.decoded = decoded_value :: decoded; undecodable_keys }
                | None ->
                    { TypeQuery.decoded; undecodable_keys = serialized_key :: undecodable_keys }
              end
          | TypeQuery.SerializedPair {
              serialized_key;
              first_serialized_value;
              second_serialized_value;
            }
            ->
              let first_decoded = decode serialized_key first_serialized_value in
              let second_decoded = decode serialized_key second_serialized_value in
              begin
                match first_decoded, second_decoded with
                | Some first, Some second ->
                    let equal =
                      match first, second with
                      | (ClassDefinitions.Decoded (_, first),
                         ClassDefinitions.Decoded (_, second)) ->
                          Option.equal (Node.equal Statement.Class.equal) first second
                      | (ClassMetadata.Decoded (_, first)), (ClassMetadata.Decoded (_, second)) ->
                          Option.equal Resolution.equal_class_metadata first second
                      | Aliases.Decoded (_, first), Aliases.Decoded (_, second) ->
                          Option.equal Type.equal first second
                      | Globals.Decoded (_, first), Globals.Decoded (_, second) ->
                          Option.equal
                            Annotation.equal
                            (first >>| Node.value)
                            (second >>| Node.value)
                      | UndecoratedFunctions.Decoded (_, first),
                        UndecoratedFunctions.Decoded (_, second) ->
                          Option.equal (Type.Callable.equal_overload Type.equal) first second
                      | Dependents.Decoded (_, first), Dependents.Decoded (_, second) ->
                          Option.equal Reference.Set.Tree.equal first second
                      | FunctionKeys.Decoded (_, first), FunctionKeys.Decoded (_, second) ->
                          Option.equal (List.equal ~equal:Reference.equal) first second
                      | ClassKeys.Decoded (_, first), ClassKeys.Decoded (_, second) ->
                          Option.equal (List.equal ~equal:Identifier.equal) first second
                      | GlobalKeys.Decoded (_, first), GlobalKeys.Decoded (_, second) ->
                          Option.equal (List.equal ~equal:Reference.equal) first second
                      | AliasKeys.Decoded (_, first), AliasKeys.Decoded (_, second) ->
                          Option.equal (List.equal ~equal:Identifier.equal) first second
                      | DependentKeys.Decoded (_, first), DependentKeys.Decoded (_, second) ->
                          Option.equal (List.equal ~equal:Reference.equal) first second
                      | OrderIndices.Decoded (_, first), OrderIndices.Decoded (_, second) ->
                          Option.equal Int.equal first second
                      | OrderAnnotations.Decoded (_, first), OrderAnnotations.Decoded (_, second) ->
                          Option.equal Type.equal first second
                      | OrderEdges.Decoded (_, first), OrderEdges.Decoded (_, second) ->
                          Option.equal (List.equal ~equal:TypeOrder.Target.equal) first second
                      | OrderBackedges.Decoded (_, first), OrderBackedges.Decoded (_, second) ->
                          Option.equal (List.equal ~equal:TypeOrder.Target.equal) first second
                      | OrderKeys.Decoded (_, first), OrderKeys.Decoded (_, second) ->
                          Option.equal (List.equal ~equal:Int.equal) first second
                      | Ast.SharedMemory.SymlinksToPaths.SymlinksToPaths.Decoded (_, first),
                        Ast.SharedMemory.SymlinksToPaths.SymlinksToPaths.Decoded (_, second) ->
                          Option.equal Path.equal first second
                      | Ast.SharedMemory.Sources.Sources.Decoded (_, first),
                        Ast.SharedMemory.Sources.Sources.Decoded (_, second) ->
                          Option.equal Source.equal first second
                      | Ast.SharedMemory.Sources.QualifiersToHandles.Decoded (_, first),
                        Ast.SharedMemory.Sources.QualifiersToHandles.Decoded (_, second) ->
                          Option.equal File.Handle.equal first second
                      | Ast.SharedMemory.HandleKeys.HandleKeys.Decoded (_, first),
                        Ast.SharedMemory.HandleKeys.HandleKeys.Decoded (_, second) ->
                          Option.equal File.Handle.Set.Tree.equal first second
                      | Ast.SharedMemory.Modules.Modules.Decoded (_, first),
                        Ast.SharedMemory.Modules.Modules.Decoded (_, second) ->
                          Option.equal Module.equal first second
                      | Ast.SharedMemory.Handles.Paths.Decoded (_, first),
                        Ast.SharedMemory.Handles.Paths.Decoded (_, second) ->
                          Option.equal String.equal first second
                      | Coverage.SharedMemory.Decoded (_, first),
                        Coverage.SharedMemory.Decoded (_, second) ->
                          Option.equal Coverage.equal first second
                      | ResolutionSharedMemory.Decoded (_, first),
                        ResolutionSharedMemory.Decoded (_, second) ->
                          Option.equal (ResolutionSharedMemory.equal_annotations) first second
                      | _ ->
                          false
                    in
                    begin
                      match serialize_decoded first, serialize_decoded second with
                      | Some (kind, key, first_value), Some (_, _, second_value)  ->
                          let value =
                            TypeQuery.DecodedPair {
                              serialized_key;
                              kind;
                              actual_key = key;
                              first_value;
                              second_value;
                              equal;
                            }
                          in
                          { TypeQuery.decoded = value :: decoded; undecodable_keys }
                      | _ ->
                          {
                            TypeQuery.decoded;
                            undecodable_keys = serialized_key :: undecodable_keys;
                          }
                    end
                | _ ->
                    { TypeQuery.decoded; undecodable_keys = serialized_key :: undecodable_keys }
              end
        in
        let decoded =
          List.fold
            values
            ~init:{ TypeQuery.decoded = []; undecodable_keys = [] }
            ~f:build_response
        in
        TypeQuery.Response (TypeQuery.Decoded decoded)
    | TypeQuery.DumpDependencies file ->
        let () =
          try
            let qualifier =
              File.handle ~configuration file
              |> fun handle -> Source.qualifier ~handle
            in
            Path.create_relative
              ~root:(Configuration.Analysis.pyre_root configuration)
              ~relative:"dependencies.dot"
            |> File.create
              ~content:(Dependencies.to_dot ~get_dependencies:Handler.dependencies ~qualifier)
            |> File.write
          with File.NonexistentHandle _ ->
            ()
        in
        TypeQuery.Response (TypeQuery.Success ())

    | TypeQuery.DumpMemoryToSqlite path ->
        let path = Path.absolute path in
        let () =
          try
            Unix.unlink path;
          with Unix.Unix_error _ ->
            ()
        in
        let timer = Timer.start () in
        (* Normalize the environment for comparison. *)
        Service.Environment.normalize_shared_memory ();
        Memory.SharedMemory.save_table_sqlite path
        |> ignore;
        let { Memory.SharedMemory.used_slots; _ } = Memory.SharedMemory.hash_stats () in
        Log.info "Dumped %d slots in %.2f seconds to %s"
          used_slots
          (Timer.stop timer |> Time.Span.to_sec)
          path;
        TypeQuery.Response (TypeQuery.Path (Path.create_absolute path))

    | TypeQuery.IsCompatibleWith (left, right) ->
        let left = parse_and_validate left in
        let right = parse_and_validate right in
        let right =
          match Type.coroutine_value right with
          | Type.Top -> right
          | unwrapped -> unwrapped
        in
        let right =
          let constraints = function
            | Type.Primitive "unknown" -> Some Type.Top
            | _ -> None
          in
          Type.instantiate right ~constraints
        in
        Resolution.is_compatible_with resolution ~left ~right
        |> (fun result ->
            TypeQuery.Response
              (TypeQuery.Compatibility { actual = left; expected = right; result })
          )

    | TypeQuery.Join (left, right) ->
        let left = parse_and_validate left in
        let right = parse_and_validate right in
        Resolution.join resolution left right
        |> (fun annotation -> TypeQuery.Response (TypeQuery.Type annotation))

    | TypeQuery.LessOrEqual (left, right) ->
        let left = parse_and_validate left in
        let right = parse_and_validate right in
        Resolution.less_or_equal resolution ~left ~right
        |> (fun response -> TypeQuery.Response (TypeQuery.Boolean response))

    | TypeQuery.Meet (left, right) ->
        let left = parse_and_validate left in
        let right = parse_and_validate right in
        Resolution.meet resolution left right
        |> (fun annotation -> TypeQuery.Response (TypeQuery.Type annotation))

    | TypeQuery.Methods annotation ->
        let to_method annotated_method =
          let open Annotated.Class.Method in
          let annotations =
            parameter_annotations ~resolution annotated_method
            |> List.mapi ~f:(fun index (_, annotation) -> index, annotation)
            |> Int.Map.of_alist_exn
          in
          let parameters =
            Map.keys annotations
            |> List.sort ~compare:Int.compare
            |> Fn.flip List.drop 1 (* Drop the self argument *)
            |> List.map ~f:(Map.find_exn annotations)
            |> fun parameters -> (Type.Primitive "self") :: parameters
          in
          let return_annotation = return_annotation ~resolution annotated_method in
          { TypeQuery.name = name annotated_method; parameters; return_annotation }
        in
        parse_and_validate (Reference.expression annotation)
        |> Type.primitive_name
        >>= Handler.class_definition
        >>| Annotated.Class.create
        >>| Annotated.Class.methods
        >>| List.map ~f:to_method
        >>| (fun methods -> TypeQuery.Response (TypeQuery.FoundMethods methods))
        |> Option.value
          ~default:(
            TypeQuery.Error
              (Format.sprintf
                 "No class definition found for %s"
                 (Reference.show annotation)))

    | TypeQuery.NormalizeType expression ->
        parse_and_validate expression
        |> (fun annotation -> TypeQuery.Response (TypeQuery.Type annotation))

    | TypeQuery.PathOfModule module_access ->
        Handler.module_definition module_access
        >>= Module.handle
        >>= File.Handle.to_path ~configuration
        >>| Path.absolute
        >>| (fun path -> TypeQuery.Response (TypeQuery.FoundPath path))
        |> Option.value
          ~default:(
            TypeQuery.Error
              (Format.sprintf
                 "No path found for module `%s`"
                 (Reference.show module_access)))

    | TypeQuery.SaveServerState path ->
        let path = Path.absolute path in
        Log.info "Saving server state into `%s`" path;
        Memory.save_shared_memory ~path;
        TypeQuery.Response (TypeQuery.Success ())

    | TypeQuery.Signature function_name ->
        let keep_known_annotation annotation =
          match annotation with
          | Type.Top ->
              None
          | _ ->
              Some annotation
        in
        begin
          match Resolution.global resolution function_name with
          | Some { Node.value; _ } ->
              begin
                match Annotation.annotation value with
                | Type.Callable { Type.Callable.implementation; overloads; _ } ->
                    let overload_signature { Type.Callable.annotation; parameters } =
                      match parameters with
                      | Type.Callable.Defined parameters ->
                          let format parameter =
                            match parameter with
                            | Type.Callable.Parameter.Named
                                { Type.Callable.Parameter.name; annotation; _ } ->
                                let name = Identifier.sanitized name in
                                Some {
                                  TypeQuery.parameter_name = name;
                                  annotation = keep_known_annotation annotation;
                                }
                            | _ ->
                                None
                          in
                          let parameters = List.filter_map ~f:format parameters in
                          Some {
                            TypeQuery.return_type = keep_known_annotation annotation;
                            parameters;
                          }
                      | _ ->
                          None
                    in
                    TypeQuery.Response
                      (TypeQuery.FoundSignature
                         (List.filter_map (implementation :: overloads) ~f:overload_signature))
                | _ ->
                    TypeQuery.Error
                      (Format.sprintf
                         "%s is not a callable"
                         (Reference.show function_name))
              end

          | None ->
              TypeQuery.Error
                (Format.sprintf
                   "No signature found for %s"
                   (Reference.show function_name))
        end

    | TypeQuery.Superclasses annotation ->
        parse_and_validate annotation
        |> Type.primitive_name
        >>= Handler.class_definition
        >>| Annotated.Class.create
        >>| Annotated.Class.superclasses ~resolution
        >>| List.map ~f:Annotated.Class.annotation
        >>| (fun classes -> TypeQuery.Response (TypeQuery.Superclasses classes))
        |> Option.value
          ~default:(
            TypeQuery.Error
              (Format.sprintf
                 "No class definition found for %s"
                 (Expression.show annotation)))

    | TypeQuery.Type expression ->
        begin
          let state =
            let define =
              Statement.Define.create_toplevel
                ~qualifier:None
                ~statements:[]
              |> Node.create_with_default_location
            in
            TypeCheck.State.create ~resolution ~define ()
          in
          let { TypeCheck.State.state; resolved = annotation; } =
            TypeCheck.State.forward_expression
              ~state
              ~expression
          in
          match TypeCheck.State.errors state with
          | [] ->
              TypeQuery.Response (TypeQuery.Type annotation)
          | errors ->
              let descriptions =
                List.map errors ~f:(Analysis.Error.description ~show_error_traces:false)
                |> String.concat ~sep:", "
              in
              TypeQuery.Error (Format.sprintf "Expression had errors: %s" descriptions)
        end

    | TypeQuery.TypeAtPosition { file; position; } ->
        let default =
          TypeQuery.Error (
            Format.asprintf
              "Not able to get lookup at %a:%a"
              Path.pp (File.path file)
              Location.pp_position position)
        in
        LookupCache.find_annotation ~state ~configuration ~file ~position
        >>| (fun (location, annotation) ->
            TypeQuery.Response (TypeQuery.TypeAtLocation { TypeQuery.location; annotation }))
        |> Option.value ~default

    | TypeQuery.TypesInFile file ->
        let default =
          TypeQuery.Error (
            Format.asprintf
              "Not able to get lookups in `%a`"
              Path.pp (File.path file))
        in
        LookupCache.find_all_annotations ~state ~configuration ~file
        >>| List.map ~f:(fun (location, annotation) -> { TypeQuery.location; annotation })
        >>| (fun list -> TypeQuery.Response (TypeQuery.TypesAtLocations list))
        |> Option.value ~default

    | TypeQuery.CoverageInFile file ->
        let default =
          TypeQuery.Error (
            Format.asprintf
              "Not able to get lookups in `%a`"
              Path.pp (File.path file))
        in
        let map_to_coverage (location, annotation) =
          let coverage =
            if Type.is_partially_typed annotation then
              TypeQuery.Partial
            else if Type.is_untyped annotation then
              TypeQuery.Untyped
            else
              TypeQuery.Typed
          in
          { location; TypeQuery.coverage }
        in
        LookupCache.find_all_annotations ~state ~configuration ~file
        >>| List.map ~f:map_to_coverage
        >>| (fun list -> TypeQuery.Response (TypeQuery.CoverageAtLocations list))
        |> Option.value ~default

  in
  let response =
    try
      process_request ()
    with
    | TypeOrder.Untracked untracked ->
        let untracked_response =
          Format.asprintf "Type `%a` was not found in the type order." Type.pp untracked
        in
        TypeQuery.Error untracked_response
    | IncorrectParameters untracked ->
        let untracked_response =
          Format.asprintf "Type `%a` has the wrong number of parameters." Type.pp untracked
        in
        TypeQuery.Error untracked_response
  in
  { state; response = Some (TypeQueryResponse response) }


let build_file_to_error_map ?(checked_files = None) ~state:{ State.errors; _ } error_list =
  let initial_files = Option.value ~default:(Hashtbl.keys errors) checked_files in
  let error_file error = File.Handle.create (Error.path error) in
  List.fold
    ~init:File.Handle.Map.empty
    ~f:(fun map key -> Map.set map ~key ~data:[])
    initial_files
  |> (fun map ->
      List.fold
        ~init:map
        ~f:(fun map error -> Map.add_multi map ~key:(error_file error) ~data:error)
        error_list)
  |> Map.to_alist


let process_type_check_files
    ~state:({
        State.environment;
        errors;
        scheduler;
        deferred_state;
        _ } as state)
    ~configuration:({ debug; _ } as configuration)
    ~files
    ~should_analyze_dependencies =

  Annotated.Class.AttributeCache.clear ();
  Module.Cache.clear ();
  Resolution.Cache.clear ();
  let removed_handles, update_environment_with, check =
    let update_handle_state (updated, removed) file =
      match File.handle ~configuration file with
      | exception (File.NonexistentHandle _) ->
          Log.warning "`%s` not found in search path." (Path.absolute (File.path file));
          updated, removed
      | handle when (not (Path.file_exists (File.path file))) ->
          updated, handle :: removed
      | handle ->
          begin
            match Ast.SharedMemory.Modules.get ~qualifier:(Source.qualifier ~handle) with
            | Some existing ->
                let existing_handle =
                  Module.handle existing
                  |> Option.value ~default:handle
                in
                if File.Handle.equal existing_handle handle then
                  (file :: updated), removed
                else if
                  (File.Handle.is_stub handle) &&
                  (not (File.Handle.is_stub existing_handle)) then
                  (* Stubs take priority over existing handles. *)
                  file :: updated, existing_handle :: removed
                else
                  updated, removed
            | _  ->
                file :: updated, removed
          end
    in
    let update_environment_with, removed_handles =
      List.fold files ~f:update_handle_state ~init:([], [])
    in
    let check = List.filter update_environment_with ~f:(fun file -> not (File.is_stub file)) in
    removed_handles,
    update_environment_with,
    check
  in
  if not (List.is_empty removed_handles) then
    List.map removed_handles ~f:File.Handle.show
    |> String.concat ~sep:", "
    |> Log.info "Removing type information for `%s`";

  let (module Handler: Environment.Handler) = environment in
  let scheduler = Scheduler.with_parallel scheduler ~is_parallel:(List.length check > 5) in

  (* Compute requests we do not serve immediately. *)
  let deferred_state =
    if should_analyze_dependencies then
      ServerDependencies.compute_dependencies
        update_environment_with
        ~state
        ~configuration
      |> fun files -> Deferred.add deferred_state ~files
    else
      deferred_state
  in

  (* Repopulate the environment. *)
  Log.info "Repopulating the environment.";
  let repopulate_handles =
    (* Clean up all data related to updated files. *)
    let timer = Timer.start () in
    let handle file =
      try
        Some (File.handle ~configuration file)
      with File.NonexistentHandle _ ->
        None
    in
    (* Watchman only notifies Pyre that a file has been updated, we have to detect
       removals manually and update our handle set. *)
    Ast.SharedMemory.HandleKeys.remove ~handles:removed_handles;
    let targets =
      let find_target file = Path.readlink (File.path file) in
      List.filter_map update_environment_with ~f:find_target
    in
    Ast.SharedMemory.SymlinksToPaths.remove ~targets;
    let handles = List.filter_map update_environment_with ~f:handle in
    Ast.SharedMemory.Sources.remove ~handles:(handles @ removed_handles);
    Handler.purge ~debug (handles @ removed_handles);
    List.iter update_environment_with ~f:(LookupCache.evict ~state ~configuration);
    Statistics.performance
      ~name:"purged old environment"
      ~timer
      ~integers:[
        "number of files", (List.length (handles @ removed_handles))
      ]
      ();

    let stubs, sources =
      let is_stub file =
        file
        |> File.path
        |> Path.absolute
        |> String.is_suffix ~suffix:".pyi"
      in
      List.partition_tf ~f:is_stub update_environment_with
    in
    Log.info "Parsing %d updated stubs..." (List.length stubs);
    let {
      Service.Parser.parsed = stubs;
      syntax_error = stub_syntax_errors;
      system_error = stub_system_errors;
    } =
      Service.Parser.parse_sources
        ~configuration
        ~scheduler
        ~preprocessing_state:None
        ~files:stubs
    in
    let sources =
      let stub_qualifiers =
        List.map stubs ~f:(fun handle -> Source.qualifier ~handle)
        |> Reference.Hash_set.of_list
      in
      let keep file =
        match handle file with
        | None ->
            false
        | Some handle ->
            let qualifier = Source.qualifier ~handle in
            if Hash_set.mem stub_qualifiers qualifier then
              false
            else
              Handler.module_definition qualifier
              >>= Module.handle
              >>| (fun existing_handle -> File.Handle.equal handle existing_handle)
              |> Option.value ~default:true
      in
      List.filter sources ~f:keep
    in
    Log.info "Parsing %d updated sources..." (List.length sources);
    let {
      Service.Parser.parsed = sources;
      syntax_error = source_syntax_errors;
      system_error = source_system_errors;
    } =
      Service.Parser.parse_sources
        ~configuration
        ~scheduler
        ~preprocessing_state:None
        ~files:sources
    in
    let unparsed =
      List.concat [
        stub_syntax_errors;
        stub_system_errors;
        source_syntax_errors;
        source_system_errors;
      ]
    in
    if not (List.is_empty unparsed) then
      Log.warning
        "Unable to parse `%s`."
        (List.map unparsed ~f:File.Handle.show
         |> String.concat ~sep:", ");
    stubs @ sources
  in
  Log.log
    ~section:`Debug
    "Repopulating the environment with %a"
    Sexp.pp [%message (repopulate_handles: File.Handle.t list)];
  Log.info "Updating the type environment for %d files." (List.length repopulate_handles);
  List.filter_map ~f:Ast.SharedMemory.Sources.get repopulate_handles
  |> Service.Environment.populate ~configuration ~scheduler environment;
  Statistics.event
    ~section:`Memory
    ~name:"shared memory size"
    ~integers:["size", Service.EnvironmentSharedMemory.heap_size ()]
    ();
  Service.Postprocess.register_ignores ~configuration scheduler repopulate_handles;

  (* Compute new set of errors. *)
 (* Clear all type resolution info from shared memory for all affected sources. *)
  ResolutionSharedMemory.remove repopulate_handles;
  Coverage.SharedMemory.remove_batch (Coverage.SharedMemory.KeySet.of_list repopulate_handles);

  let new_errors =
    Service.Check.analyze_sources
      ~scheduler
      ~configuration
      ~environment
      ~handles:repopulate_handles
  in
  (* Kill all previous errors for new files we just checked *)
  List.iter ~f:(Hashtbl.remove errors) (removed_handles @ repopulate_handles);
  (* Associate the new errors with new files *)
  List.iter
    new_errors
    ~f:(fun error ->
        Hashtbl.add_multi errors ~key:(File.Handle.create (Error.path error)) ~data:error);
  let checked_files =
    List.filter_map
      ~f:(fun file -> try
             Some (File.handle ~configuration file)
           with File.NonexistentHandle _ ->
             Log.warning
               "Could not create a handle for %s. It will be excluded from the type-check response."
               (Path.absolute (File.path file));
             None
         )
      check
    |> Option.some
  in
  {
    state = { state with deferred_state };
    response = Some (TypeCheckResponse (build_file_to_error_map ~checked_files ~state new_errors));
  }


let process_type_check_request
    ~state
    ~configuration
    ~files =
  process_type_check_files ~state ~configuration ~files ~should_analyze_dependencies:true


let process_deferred_state
    ~state:({ State.deferred_state; _ } as state)
    ~configuration:({ number_of_workers; _ } as configuration)
    ~flush =
  (* The chunk size is an heuristic - the attempt is to have a request that can be completed
     in a few seconds. *)
  SharedMem.collect `aggressive;
  let current_batch, remaining =
    if flush then
      File.Set.to_list deferred_state, File.Set.empty
    else
      Deferred.take_n ~elements:number_of_workers deferred_state
  in
  if List.length current_batch > 0 then
    begin
      let remaining_message =
        let length = Deferred.length remaining in
        if length <> 0 then
          Format.sprintf ", %d remaining." length
        else
          "."
      in
      Log.info
        "Processing %d deferred requests%s"
        (List.length current_batch)
        remaining_message;
      let state = { state with deferred_state = remaining } in
      process_type_check_files
        ~state
        ~configuration
        ~files:current_batch
        ~should_analyze_dependencies:false
    end
  else
    { state; response = None }


let process_display_type_errors_request ~state ~configuration ~files ~flush =
  let state =
    if flush then
      let { state; _ } = process_deferred_state ~state ~configuration ~flush:true in
      state
    else
      state
  in
  let errors =
    let { errors; _ } = state in
    match files with
    | [] ->
        Hashtbl.data errors
        |> List.concat
        |> List.sort ~compare:Error.compare
    | _ ->
        let errors file =
          try
            File.handle ~configuration file
            |> Hashtbl.find errors
            |> Option.value ~default:[]
          with (File.NonexistentHandle _) ->
            []
        in
        List.concat_map ~f:errors files
  in
  { state; response = Some (TypeCheckResponse (build_file_to_error_map ~state errors)) }


let process_get_definition_request
    ~state
    ~configuration
    ~request:{ DefinitionRequest.id; file; position } =
  let response =
    let open LanguageServer.Protocol in
    let definition = LookupCache.find_definition ~state ~configuration file position in
    TextDocumentDefinitionResponse.create ~configuration ~id ~location:definition
    |> TextDocumentDefinitionResponse.to_yojson
    |> Yojson.Safe.to_string
    |> (fun response -> LanguageServerProtocolResponse response)
    |> Option.some
  in
  { state; response }


let rec process
    ~socket
    ~state:({ State.environment; lock; connections; _ } as state)
    ~configuration:({
        configuration;
        _;
      } as server_configuration)
    ~request =
  let timer = Timer.start () in
  let (module Handler: Environment.Handler) = environment in
  let log_request_error ~error =
    Statistics.event
      ~section:`Error
      ~name:"request error"
      ~normals:[
        "request", Request.show request;
        "error", error;
      ]
      ~flush:true
      ()
  in
  let result =
    try
      match request with
      | TypeCheckRequest files ->
          SharedMem.collect `aggressive;
          process_type_check_request ~state ~configuration ~files

      | TypeQueryRequest request ->
          process_type_query_request ~state ~configuration ~request

      | DisplayTypeErrors { files; flush } ->
          process_display_type_errors_request ~state ~configuration ~files ~flush

      | StopRequest ->
          Socket.write socket StopResponse;
          Mutex.critical_section
            lock
            ~f:(fun () ->
                Operations.stop
                  ~reason:"explicit request"
                  ~configuration:server_configuration
                  ~socket:!connections.socket);
          { state; response = None }

      | LanguageServerProtocolRequest request ->
          parse_lsp
            ~configuration
            ~request:(Yojson.Safe.from_string request)
          >>| (fun request -> process ~state ~socket ~configuration:server_configuration ~request)
          |> Option.value ~default:{ state; response = None }

      | ClientShutdownRequest id ->
          process_client_shutdown_request ~state ~id

      | ClientExitRequest client ->
          Log.log ~section:`Server "Stopping %s client" (show_client client);
          { state; response = Some (ClientExitResponse client) }

      | RageRequest id ->
          let response =
            let items = Service.Rage.get_logs configuration in
            LanguageServer.Protocol.RageResponse.create ~items ~id
            |> LanguageServer.Protocol.RageResponse.to_yojson
            |> Yojson.Safe.to_string
            |> (fun response -> LanguageServerProtocolResponse response)
            |> Option.some
          in
          { state; response }

      | GetDefinitionRequest request ->
          process_get_definition_request ~state ~configuration ~request

      | HoverRequest { DefinitionRequest.id; file; position } ->
          let response =
            let open LanguageServer.Protocol in
            let result =
              LookupCache.find_annotation ~state ~configuration ~file ~position
              >>| fun (location, annotation) ->
              {
                HoverResponse.location;
                contents = Type.show annotation;
              }
            in
            HoverResponse.create ~id ~result
            |> HoverResponse.to_yojson
            |> Yojson.Safe.to_string
            |> (fun response -> LanguageServerProtocolResponse response)
            |> Option.some
          in
          { state; response }

      | CodeActionRequest _ ->
          { state; response = None }

      | OpenDocument file ->
          (* Make sure cache is fresh. We might not have received a close notification. *)
          LookupCache.evict ~state ~configuration file;
          (* Make sure the IDE flushes its state about this file, by sending back all the
             errors for this file. *)
          process_type_check_request
            ~state
            ~configuration
            ~files:[file]

      | CloseDocument file ->
          LookupCache.evict ~state ~configuration file;
          { state; response = None }

      | SaveDocument file ->
          (* On save, evict entries from the lookup cache. The updated
             source will be picked up at the next lookup (if any). *)
          LookupCache.evict ~state ~configuration file;
          let check_on_save =
            Mutex.critical_section
              lock
              ~f:(fun () ->
                  let { file_notifiers; _ } = !connections in
                  List.is_empty file_notifiers)
          in
          if check_on_save then
            process_type_check_request
              ~state
              ~configuration
              ~files:[file]
          else
            begin
              Log.log ~section:`Server "Explicitly ignoring didSave request";
              { state; response = None }
            end

      (* Requests that cannot be fulfilled here. *)
      | ClientConnectionRequest _ ->
          Log.warning  "Explicitly ignoring ClientConnectionRequest request";
          { state; response = None }
    with
    | Unix.Unix_error (kind, name, parameters) ->
        Log.log_unix_error (kind, name, parameters);
        log_request_error
          ~error:(Format.sprintf "Unix error %s: %s(%s)" (Unix.error_message kind) name parameters);
        { state; response = None }
    | Analysis.TypeOrder.Untracked annotation ->
        log_request_error ~error:(Format.sprintf "Untracked %s" (Type.show annotation));
        { state; response = None }
    | uncaught_exception ->
        let should_stop =
          match request with
          | HoverRequest _
          | GetDefinitionRequest _ ->
              false
          | _ ->
              true
        in
        Statistics.log_exception uncaught_exception ~fatal:should_stop ~origin:"server";
        if should_stop then
          Mutex.critical_section
            lock
            ~f:(fun () ->
                Operations.stop
                  ~reason:"uncaught exception"
                  ~configuration:server_configuration
                  ~socket:!connections.socket);
        { state; response = None }

  in
  Statistics.performance
    ~name:"server request"
    ~timer
    ~normals:["request kind", Request.name request]
    ();
  result

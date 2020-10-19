(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open OUnit2
open Ast
open Analysis
open Test
open Interprocedural

let test_call_graph_of_define context =
  let assert_call_graph_of_define ~source ~define_name ~expected =
    let expected =
      let parse_location location =
        let parse_position position =
          let line_and_column = String.split ~on:':' position in
          {
            Location.line = Int.of_string (List.nth_exn line_and_column 0);
            column = Int.of_string (List.nth_exn line_and_column 1);
          }
        in
        let positions = String.split ~on:'-' location in
        {
          Location.start = parse_position (List.nth_exn positions 0);
          stop = parse_position (List.nth_exn positions 1);
        }
      in
      List.map expected ~f:(fun (key, value) -> parse_location key, value)
      |> Location.Map.of_alist_exn
    in
    let define, test_source, environment =
      let find_define = function
        | { Node.value = Statement.Statement.Define define; _ }
          when String.equal (Reference.show (Node.value (Statement.Define.name define))) define_name
          ->
            Some define
        | _ -> None
      in
      let project = Test.ScratchProject.setup ~context ["test.py", source] in
      let { ScratchProject.BuiltTypeEnvironment.type_environment; sources } =
        ScratchProject.build_type_environment project
      in
      let test_source =
        List.find_map_exn
          sources
          ~f:(fun ({ Source.source_path = { SourcePath.qualifier; _ }; _ } as source) ->
            Option.some_if (String.equal (Reference.show qualifier) "test") source)
      in
      ( List.find_map_exn (Ast.Source.statements test_source) ~f:find_define,
        test_source,
        TypeEnvironment.read_only type_environment )
    in
    let overrides = DependencyGraph.create_overrides ~environment ~source:test_source in
    DependencyGraphSharedMemory.record_overrides overrides;
    assert_equal
      ~cmp:(Location.Map.equal CallGraph.equal_callees)
      ~printer:(fun map ->
        map
        |> Location.Map.to_alist
        |> List.map ~f:(fun (key, value) ->
               Format.sprintf "%s: %s" (Location.show key) (CallGraph.show_callees value))
        |> String.concat ~sep:"\n")
      expected
      (CallGraph.call_graph_of_define ~environment ~define);
    DependencyGraphSharedMemory.remove_overriding_types (Reference.Map.keys overrides)
  in
  assert_call_graph_of_define
    ~source:{|
     def foo():
         bar()

     def bar():
         pass
  |}
    ~define_name:"test.foo"
    ~expected:
      [
        ( "3:4-3:9",
          CallGraph.RegularTargets { implicit_self = false; targets = [`Function "test.bar"] } );
      ];
  assert_call_graph_of_define
    ~source:
      {|
     def foo(c: C):
         c.m()

     class C:
       def m(self):
         pass
      |}
    ~define_name:"test.foo"
    ~expected:
      [
        ( "3:4-3:9",
          CallGraph.RegularTargets
            {
              implicit_self = true;
              targets = [Callable.create_method (Reference.create "test.C.m")];
            } );
      ];
  assert_call_graph_of_define
    ~source:
      {|
     def foo():
       if 1 > 2:
         f = bar
       else:
         f = baz
       f()
     def baz(): ...
     def bar(): ...
      |}
    ~define_name:"test.foo"
    ~expected:
      [
        ( "7:2-7:5",
          CallGraph.RegularTargets
            { implicit_self = false; targets = [`Function "test.bar"; `Function "test.baz"] } );
        ( "3:5-3:10",
          CallGraph.RegularTargets
            {
              implicit_self = true;
              targets = [`Method { Callable.class_name = "int"; method_name = "__le__" }];
            } );
      ];
  assert_call_graph_of_define
    ~source:
      {|
     def foo():
       if 1 > 2:
         f = bar
       else:
         f = None
       f()
     def bar(): ...
      |}
    ~define_name:"test.foo"
    ~expected:
      [
        ( "3:5-3:10",
          CallGraph.RegularTargets
            {
              implicit_self = true;
              targets = [`Method { Callable.class_name = "int"; method_name = "__le__" }];
            } );
        ( "7:2-7:5",
          CallGraph.RegularTargets { implicit_self = false; targets = [`Function "test.bar"] } );
      ];
  assert_call_graph_of_define
    ~source:
      {|
     from typing import Optional

     def foo(c: Optional[C]):
       c.m()
     class C:
       def m():
         ...

      |}
    ~define_name:"test.foo"
    ~expected:
      [
        ( "5:2-5:7",
          CallGraph.RegularTargets
            {
              implicit_self = true;
              targets = [Callable.create_method (Reference.create "test.C.m")];
            } );
      ];
  assert_call_graph_of_define
    ~source:
      {|
     from typing import Optional

     def foo(c: C):
       c.m()
     class C:
       def m():
         ...
     class D(C):
       def m():
         ...
     class E(D):
       def m():
         ...
      |}
    ~define_name:"test.foo"
    ~expected:
      [
        ( "5:2-5:7",
          CallGraph.RegularTargets
            {
              implicit_self = true;
              targets = [Callable.create_override (Reference.create "test.C.m")];
            } );
      ];
  assert_call_graph_of_define
    ~source:
      {|
     from typing import Optional

     def foo(d: D):
       d.m()
     class C:
       def m():
         ...
     class D(C):
       pass
     class E(D):
       def m():
         ...
      |}
    ~define_name:"test.foo"
    ~expected:
      [
        ( "5:2-5:7",
          CallGraph.RegularTargets
            {
              implicit_self = true;
              targets =
                [
                  Callable.create_method (Reference.create "test.C.m");
                  Callable.create_method (Reference.create "test.E.m");
                ];
            } );
      ];
  assert_call_graph_of_define
    ~source:
      {|
    class C:
      def __call__(self, a: int): ...
    def foo(c: C):
       c(1)
    |}
    ~define_name:"test.foo"
    ~expected:
      [
        ( "5:3-5:7",
          CallGraph.RegularTargets
            {
              implicit_self = true;
              targets = [Callable.create_method (Reference.create "test.C.__call__")];
            } );
      ];
  assert_call_graph_of_define
    ~source:
      {|
    class C:
      @staticmethod
      def __call__(a: int): ...
    def foo(c: C):
       c(1)
    |}
    ~define_name:"test.foo"
    ~expected:
      [
        ( "6:3-6:7",
          CallGraph.RegularTargets
            {
              implicit_self = false;
              targets = [Callable.create_method (Reference.create "test.C.__call__")];
            } );
      ];
  assert_call_graph_of_define
    ~source:
      {|
    from typing import Protocol
    class C(Protocol):
      def __call__(self, a: int): ...
    def foo(c: C):
       c(1)
    |}
    ~define_name:"test.foo"
    ~expected:
      [
        ( "6:3-6:7",
          CallGraph.RegularTargets
            {
              implicit_self = true;
              targets = [Callable.create_method (Reference.create "test.C.__call__")];
            } );
      ];
  assert_call_graph_of_define
    ~source:
      {|
       class C:
         def __init__(self, a): ...
       def foo():
         C()
    |}
    ~define_name:"test.foo"
    ~expected:
      [
        ( "5:2-5:5",
          CallGraph.ConstructorTargets
            {
              init_targets = [`Method { Callable.class_name = "test.C"; method_name = "__init__" }];
              new_targets = [`Method { Callable.class_name = "object"; method_name = "__new__" }];
            } );
      ];
  assert_call_graph_of_define
    ~source:
      {|
       class C:
         def __new__(cls, a): ...
       def foo():
         C()
    |}
    ~define_name:"test.foo"
    ~expected:
      [
        ( "5:2-5:5",
          CallGraph.ConstructorTargets
            {
              init_targets = [`Method { Callable.class_name = "object"; method_name = "__init__" }];
              new_targets = [`Method { Callable.class_name = "test.C"; method_name = "__new__" }];
            } );
      ];
  assert_call_graph_of_define
    ~source:
      {|
        class C:
          @property
          def p(self) -> int: ...
          @p.setter
          def p(self, v: int) -> None: ...
        def foo(c: C):
          c.p = c.p
      |}
    ~define_name:"test.foo"
    ~expected:
      [
        ( "8:2-8:5",
          CallGraph.RegularTargets
            {
              implicit_self = true;
              targets = [`Method { Callable.class_name = "test.C"; method_name = "p$setter" }];
            } );
        ( "8:8-8:11",
          CallGraph.RegularTargets
            {
              implicit_self = true;
              targets = [`Method { Callable.class_name = "test.C"; method_name = "p" }];
            } );
      ];
  assert_call_graph_of_define
    ~source:
      {|
        class C:
          @staticmethod
          def f(a: int) -> int: ...
        def foo():
          C.f()
      |}
    ~define_name:"test.foo"
    ~expected:
      [
        ( "6:2-6:7",
          CallGraph.RegularTargets
            {
              implicit_self = false;
              targets = [`Method { Callable.class_name = "test.C"; method_name = "f" }];
            } );
      ];
  assert_call_graph_of_define
    ~source:{|
        def foo():
          1 > 2
      |}
    ~define_name:"test.foo"
    ~expected:
      [
        ( "3:2-3:7",
          CallGraph.RegularTargets
            {
              implicit_self = true;
              targets = [`Method { Callable.class_name = "int"; method_name = "__gt__" }];
            } );
      ];
  assert_call_graph_of_define
    ~source:
      {|
      class C:
        def __repr__(self) -> str: ...

      def foo(c: C):
        repr(c)
    |}
    ~define_name:"test.foo"
    ~expected:
      [
        ( "6:2-6:9",
          CallGraph.RegularTargets
            {
              implicit_self = true;
              targets = [`Method { Callable.class_name = "test.C"; method_name = "__repr__" }];
            } );
      ];
  assert_call_graph_of_define
    ~source:
      {|
      from functools import partial
      def f(a, b):
        ...

      def foo():
        partial(f, 1)
    |}
    ~define_name:"test.foo"
    ~expected:
      [
        ( "7:2-7:15",
          CallGraph.RegularTargets { implicit_self = false; targets = [`Function "test.f"] } );
      ];
  assert_call_graph_of_define
    ~source:
      {|
      from builtins import to_callable_target

      @to_callable_target
      def callable_target(arg):
        pass

      def foo():
        callable_target.async_schedule(1)
      |}
    ~define_name:"test.foo"
    ~expected:
      [
        ( "9:2-9:35",
          CallGraph.RegularTargets
            { implicit_self = false; targets = [`Function "test.callable_target"] } );
      ];
  assert_call_graph_of_define
    ~source:{|
      def foo(x=bar()):
        pass

      def bar():
        pass
      |}
    ~define_name:"test.foo"
    ~expected:
      [
        ( "2:10-2:15",
          CallGraph.RegularTargets { implicit_self = false; targets = [`Function "test.bar"] } );
      ]


let test_resolve_ignoring_optional context =
  let assert_resolved_without_optional ~source ~expression ~expected =
    let resolution =
      ScratchProject.setup ~context ["x.py", source] |> ScratchProject.build_resolution
    in
    CallGraph.resolve_ignoring_optional ~resolution (Test.parse_single_expression expression)
    |> assert_equal ~printer:Type.show expected
  in
  assert_resolved_without_optional
    ~source:{|
    class Data:
      def __init__(self, x: int) -> None: ...
  |}
    ~expression:"x.Data()"
    ~expected:(Type.Primitive "x.Data")


let () =
  "interproceduralCallGraph"
  >::: [
         "call_graph_of_define" >:: test_call_graph_of_define;
         "resolve_ignoring_optional" >:: test_resolve_ignoring_optional;
       ]
  |> Test.run

module Steep
  class TypeConstruction
    module Types
      module_function

      def any
        AST::Types::Any.new
      end

      def symbol_instance
        AST::Types::Name.new_instance(name: "::Symbol")
      end

      def nil_instance
        AST::Types::Name.new_instance(name: "::NilClass")
      end

      def string_instance
        AST::Types::Name.new_instance(name: "::String")
      end

      def array_instance(type)
        AST::Types::Name.new_instance(name: "::Array", args: [type])
      end

      def range_instance(type)
        AST::Types::Name.new_instance(name: "::Range", args: [type])
      end
    end

    class MethodContext
      attr_reader :name
      attr_reader :method
      attr_reader :method_type
      attr_reader :return_type
      attr_reader :constructor

      def initialize(name:, method:, method_type:, return_type:, constructor:)
        @name = name
        @method = method
        @return_type = return_type
        @method_type = method_type
        @constructor = constructor
      end

      def block_type
        method_type&.block
      end

      def super_method
        method&.super_method
      end
    end

    class BlockContext
      attr_reader :body_type

      def initialize(body_type:)
        @body_type = body_type
      end
    end

    class BreakContext
      attr_reader :break_type
      attr_reader :next_type

      def initialize(break_type:, next_type:)
        @break_type = break_type
        @next_type = next_type
      end
    end

    class ModuleContext
      attr_reader :instance_type
      attr_reader :module_type
      attr_reader :defined_instance_methods
      attr_reader :defined_module_methods
      attr_reader :const_env
      attr_reader :implement_name
      attr_reader :current_namespace

      def initialize(instance_type:, module_type:, implement_name:, current_namespace:, const_env:)
        @instance_type = instance_type
        @module_type = module_type
        @defined_instance_methods = Set.new
        @defined_module_methods = Set.new
        @implement_name = implement_name
        @current_namespace = current_namespace
        @const_env = const_env
      end
    end

    attr_reader :checker
    attr_reader :source
    attr_reader :annotations
    attr_reader :typing
    attr_reader :method_context
    attr_reader :block_context
    attr_reader :module_context
    attr_reader :self_type
    attr_reader :break_context
    attr_reader :type_env

    def initialize(checker:, source:, annotations:, type_env:, typing:, self_type:, method_context:, block_context:, module_context:, break_context:)
      @checker = checker
      @source = source
      @annotations = annotations
      @typing = typing
      @self_type = self_type
      @block_context = block_context
      @method_context = method_context
      @module_context = module_context
      @break_context = break_context
      @type_env = type_env
    end

    def for_new_method(method_name, node, args:, self_type:)
      annots = source.annotations(block: node)
      type_env = TypeInference::TypeEnv.new(subtyping: checker,
                                            const_env: module_context&.const_env || self.type_env.const_env)

      self.type_env.const_types.each do |name, type|
        type_env.set(const: name, type: type)
      end

      self_type = annots.self_type || self_type

      self_interface = self_type && (self_type != Types.any || nil) && checker.resolve(self_type, with_initialize: true)
      interface_method = self_interface&.yield_self {|interface| interface.methods[method_name] }
      annotation_method = annotations.lookup_method_type(method_name)&.yield_self do |method_type|
        Interface::Method.new(type_name: nil,
                              name: method_name,
                              types: [checker.builder.method_type_to_method_type(method_type,
                                                                                 current: current_namespace)],
                              super_method: interface_method&.super_method,
                              attributes: [])
      end

      if interface_method && annotation_method
        result = checker.check_method(method_name,
                                      annotation_method,
                                      interface_method,
                                      assumption: Set.new,
                                      trace: Subtyping::Trace.new,
                                      constraints: Subtyping::Constraints.empty)

        if result.failure?
          typing.add_error Errors::IncompatibleMethodTypeAnnotation.new(
            node: node,
            annotation_method: annotation_method,
            interface_method: interface_method,
            result: result
          )
        end
      end

      method = annotation_method || interface_method

      case
      when method && method.types.size == 1
        method_type = method.types.first
        return_type = method_type.return_type
        var_types = TypeConstruction.parameter_types(args, method_type).transform_values {|type| absolute_type(type) }
        unless TypeConstruction.valid_parameter_env?(var_types, args, method_type.params)
          typing.add_error Errors::MethodArityMismatch.new(node: node)
        end
      when method
        typing.add_error Errors::MethodDefinitionWithOverloading.new(node: node, method: method)
        return_type = union_type(*method.types.map(&:return_type))
        var_types = {}
      else
        var_types = {}
      end

      if annots.return_type && return_type
        return_type_relation = Subtyping::Relation.new(sub_type: annots.return_type,
                                                       super_type: return_type)
        checker.check(return_type_relation, constraints: Subtyping::Constraints.empty).else do |result|
          typing.add_error Errors::MethodReturnTypeAnnotationMismatch.new(node: node,
                                                                          method_type: return_type,
                                                                          annotation_type: annots.return_type,
                                                                          result: result)
        end
      end

      constructor_method = method&.attributes&.include?(:constructor)

      method_context = MethodContext.new(
        name: method_name,
        method: method,
        method_type: method_type,
        return_type: annots.return_type || return_type,
        constructor: constructor_method
      )

      var_types.each do |name, type|
        type_env.set(lvar: name, type: type)
      end

      ivar_types = {}
      ivar_types.merge!(self_interface.ivars) if self_interface
      ivar_types.merge!(annots.ivar_types)

      ivar_types.each do |name, type|
        type_env.set(ivar: name, type: type)
      end

      type_env = type_env.with_annotations(
        lvar_types: annots.var_types.transform_values {|annot| absolute_type(annot.type) },
        ivar_types: annots.ivar_types,
        const_types: annots.const_types.transform_values {|type| absolute_type(type) }
      )

      self.class.new(
        checker: checker,
        source: source,
        annotations: annots,
        type_env: type_env,
        block_context: nil,
        self_type: self_type,
        method_context: method_context,
        typing: typing,
        module_context: module_context,
        break_context: nil
      )
    end

    def for_module(node)
      annots = source.annotations(block: node)
      new_module_name = ModuleName.from_node(node.children.first) or raise "Unexpected module name: #{node.children.first}"

      module_type = AST::Types::Name.new_instance(name: "::Module")

      implement_module_name =
        if annots.implement_module
          annots.implement_module.name
        else
          absolute_name(new_module_name).yield_self do |module_name|
            if checker.builder.signatures.module_name?(module_name)
              signature = checker.builder.signatures.find_module(module_name)
              AST::Annotation::Implements::Module.new(name: module_name,
                                                      args: signature.params&.variables || [])
            end
          end
        end

      if implement_module_name
        module_name = implement_module_name.name
        module_args = implement_module_name.args.map {|x| AST::Types::Var.new(name: x) }

        abstract = checker.builder.build(TypeName::Instance.new(name: module_name))

        instance_type = absolute_type(
          AST::Types::Name.new_instance(name: module_name, args: module_args)
        )

        unless abstract.supers.empty?
          instance_type = AST::Types::Intersection.build(
            types: [instance_type, AST::Types::Name.new_instance(name: "::Object")] + abstract.supers.map {|x| absolute_type(x) }
          )
        end

        module_type = AST::Types::Intersection.build(types: [
          AST::Types::Name.new_instance(name: "::Module"),
          absolute_type(AST::Types::Name.new_module(name: module_name, args: module_args))
        ])
      end

      if annots.instance_type
        instance_type = absolute_type(annots.instance_type)
      end

      if annots.module_type
        module_type = absolute_type(annots.module_type)
      end

      new_namespace = nested_namespace(new_module_name)
      module_const_env = TypeInference::ConstantEnv.new(builder: checker.builder, current_namespace: new_namespace)

      module_context_ = ModuleContext.new(
        instance_type: instance_type,
        module_type: module_type,
        implement_name: implement_module_name,
        current_namespace: new_namespace,
        const_env: module_const_env
      )

      module_type_env = TypeInference::TypeEnv.build(annotations: annots,
                                                     subtyping: checker,
                                                     const_env: module_const_env,
                                                     signatures: checker.builder.signatures)

      self.class.new(
        checker: checker,
        source: source,
        annotations: annots,
        type_env: module_type_env,
        typing: typing,
        method_context: nil,
        block_context: nil,
        module_context: module_context_,
        self_type: module_context_.module_type,
        break_context: nil
      )
    end

    def for_class(node)
      annots = source.annotations(block: node)
      new_class_name = ModuleName.from_node(node.children.first) or raise "Unexpected class name: #{node.children.first}"

      implement_module_name =
        if annots.implement_module
          annots.implement_module.name
        else
          absolute_name(new_class_name).yield_self do |name|
            if checker.builder.signatures.class_name?(name)
              signature = checker.builder.signatures.find_class(name)
              AST::Annotation::Implements::Module.new(name: name,
                                                      args: signature.params&.variables || [])
            end
          end
        end

      if implement_module_name
        class_name = implement_module_name.name
        class_args = implement_module_name.args.map {|x| AST::Types::Var.new(name: x) }

        _ = checker.builder.build(TypeName::Instance.new(name: class_name))

        instance_type = AST::Types::Name.new_instance(name: class_name, args: class_args)
        module_type = AST::Types::Name.new_class(name: class_name, args: [], constructor: nil)
      end

      new_namespace = nested_namespace(new_class_name)
      class_const_env = TypeInference::ConstantEnv.new(builder: checker.builder, current_namespace: new_namespace)

      module_context = ModuleContext.new(
        instance_type: annots.instance_type || instance_type,
        module_type: annots.module_type || module_type,
        implement_name: implement_module_name,
        current_namespace: new_namespace,
        const_env: class_const_env
      )

      class_type_env = TypeInference::TypeEnv.build(
        annotations: annots,
        const_env: class_const_env,
        signatures: checker.builder.signatures,
        subtyping: checker
      )

      self.class.new(
        checker: checker,
        source: source,
        annotations: annots,
        type_env: class_type_env,
        typing: typing,
        method_context: nil,
        block_context: nil,
        module_context: module_context,
        self_type: module_context.module_type,
        break_context: nil
      )
    end

    def for_branch(node, type_case_override: nil)
      annots = source.annotations(block: node)

      type_env = self.type_env

      if type_case_override
        type_env = type_env.with_annotations(lvar_types: type_case_override) do |var, relation, result|
          typing.add_error(
            Errors::IncompatibleTypeCase.new(node: node,
                                             var_name: var,
                                             relation: relation,
                                             result: result)
          )
        end
      end

      type_env = type_env.with_annotations(
        lvar_types: annots.var_types.transform_values {|a| absolute_type(a.type) },
        ivar_types: annots.ivar_types.transform_values {|ty| absolute_type(ty) },
        const_types: annots.const_types.transform_values {|ty| absolute_type(ty) },
        gvar_types: {}
      ) do |var, relation, result|
        typing.add_error(
          Errors::IncompatibleAnnotation.new(node: node,
                                             var_name: var,
                                             relation: relation,
                                             result: result)
        )
      end

      with(type_env: type_env)
    end

    NOTHING = ::Object.new

    def with(annotations: NOTHING, type_env: NOTHING, method_context: NOTHING, block_context: NOTHING, module_context: NOTHING, self_type: NOTHING, break_context: NOTHING)
      self.class.new(
        checker: checker,
        source: source,
        annotations: annotations.equal?(NOTHING) ? self.annotations : annotations,
        type_env: type_env.equal?(NOTHING) ? self.type_env : type_env,
        typing: typing,
        method_context: method_context.equal?(NOTHING) ? self.method_context : method_context,
        block_context: block_context.equal?(NOTHING) ? self.block_context : block_context,
        module_context: module_context.equal?(NOTHING) ? self.module_context : module_context,
        self_type: self_type.equal?(NOTHING) ? self.self_type : self_type,
        break_context: break_context.equal?(NOTHING) ? self.break_context : break_context
      )
    end

    def synthesize(node)
      Steep.logger.tagged "synthesize:(#{node.location.expression.to_s.split(/:/, 2).last})" do
        Steep.logger.debug node.type
        case node.type
        when :begin, :kwbegin
          yield_self do
            type = each_child_node(node).map do |child|
              synthesize(child)
            end.last

            typing.add_typing(node, type)
          end

        when :lvasgn
          yield_self do
            var = node.children[0]
            rhs = node.children[1]

            if var.name == :_
              typing.add_typing(node, Types.any)
            else
              type_assignment(var, rhs, node)
            end
          end

        when :lvar
          yield_self do
            var = node.children[0]
            type = type_env.get(lvar: var.name) do
              fallback_to_any node
            end

            typing.add_typing node, type
          end

        when :ivasgn
          name = node.children[0]
          value = node.children[1]

          type_ivasgn(name, value, node)

        when :ivar
          yield_self do
            name = node.children[0]
            type = type_env.get(ivar: name) do
              fallback_to_any node
            end
            typing.add_typing(node, type)
          end

        when :send
          yield_self do
            if self_class?(node)
              module_type = module_context.module_type
              type = if module_type.is_a?(AST::Types::Name)
                       AST::Types::Name.new(name: module_type.name.updated(constructor: method_context.constructor),
                                            args: module_type.args)
                     else
                       module_type
                     end
              typing.add_typing(node, type)
            else
              type_send(node, send_node: node, block_params: nil, block_body: nil)
            end
          end

        when :op_asgn
          yield_self do
            lhs, op, rhs = node.children

            synthesize(rhs)

            lhs_type = case lhs.type
                       when :lvasgn
                         type_env.get(lvar: lhs.children.first.name) do
                           break
                         end
                       when :ivasgn
                         type_env.get(ivar: lhs.children.first) do
                           break
                         end
                       else
                         raise
                       end

            case
            when lhs_type == Types.any
              typing.add_typing(node, lhs_type)
            when !lhs_type
              fallback_to_any(node)
            else
              lhs_interface = checker.resolve(lhs_type, with_initialize: false)
              op_method = lhs_interface.methods[op]

              if op_method
                args = TypeInference::SendArgs.from_nodes([rhs])
                return_type_or_error = type_method_call(node, method: op_method, args: args, block_params: nil, block_body: nil)

                if return_type_or_error.is_a?(Errors::Base)
                  typing.add_error return_type_or_error
                else
                  result = checker.check(
                    Subtyping::Relation.new(sub_type: return_type_or_error, super_type: lhs_type),
                    constraints: Subtyping::Constraints.empty
                  )
                  if result.failure?
                    typing.add_error(
                      Errors::IncompatibleAssignment.new(
                        node: node,
                        lhs_type: lhs_type,
                        rhs_type: return_type_or_error,
                        result: result
                      )
                    )
                  end
                end
              else
                typing.add_error Errors::NoMethod.new(node: node, method: op, type: lhs_type)
              end

              typing.add_typing(node, lhs_type)
            end
          end

        when :super
          yield_self do
            if self_type && method_context&.method
              if method_context.super_method
                each_child_node(node) do |child| synthesize(child) end

                super_method = method_context.super_method
                args = TypeInference::SendArgs.from_nodes(node.children.dup)

                return_type_or_error = type_method_call(node, method: super_method, args: args, block_params: nil, block_body: nil)

                if return_type_or_error.is_a?(Errors::Base)
                  fallback_to_any node do
                    return_type_or_error
                  end
                else
                  typing.add_typing node, return_type_or_error
                end
              else
                fallback_to_any node do
                  Errors::UnexpectedSuper.new(node: node, method: method_context.name)
                end
              end
            else
              typing.add_typing node, Types.any
            end
          end

        when :block
          yield_self do
            send_node, params, body = node.children
            type_send(node, send_node: send_node, block_params: params, block_body: body)
          end

        when :def
          new = for_new_method(node.children[0],
                               node,
                               args: node.children[1].children,
                               self_type: module_context&.instance_type)

          each_child_node(node.children[1]) do |arg|
            new.synthesize(arg)
          end

          if node.children[2]
            return_type = new.method_context&.return_type
            if return_type && !return_type.is_a?(AST::Types::Void)
              new.check(node.children[2], return_type) do |_, actual_type, result|
                typing.add_error(Errors::MethodBodyTypeMismatch.new(node: node,
                                                                    expected: return_type,
                                                                    actual: actual_type,
                                                                    result: result))
              end
            else
              new.synthesize(node.children[2])
            end
          end

          if module_context
            module_context.defined_instance_methods << node.children[0]
          end

          typing.add_typing(node, Types.any)

        when :defs
          synthesize(node.children[0]).tap do |self_type|
            new = for_new_method(node.children[1],
                                 node,
                                 args: node.children[2].children,
                                 self_type: self_type)

            each_child_node(node.children[2]) do |arg|
              new.synthesize(arg)
            end

            if node.children[3]
              return_type = new.method_context&.return_type
              if return_type && !return_type.is_a?(AST::Types::Void)
                new.check(node.children[3], return_type) do |return_type, actual_type, result|
                  typing.add_error(Errors::MethodBodyTypeMismatch.new(node: node,
                                                                      expected: return_type,
                                                                      actual: actual_type,
                                                                      result: result))
                end
              else
                new.synthesize(node.children[3])
              end
            end
          end

          if module_context
            if node.children[0].type == :self
              module_context.defined_module_methods << node.children[1]
            end
          end

          typing.add_typing(node, Types.symbol_instance)

        when :return
          yield_self do
            if node.children.size > 0
              return_types = node.children.map do |value|
                synthesize(value)
              end

              value_type = if return_types.size == 1
                             return_types.first
                           else
                             Types.array_instance(union_type(*return_types))
                           end

              if method_context&.return_type && !method_context.return_type.is_a?(AST::Types::Void)
                result = checker.check(
                  Subtyping::Relation.new(sub_type: value_type,
                                          super_type: method_context.return_type),
                  constraints: Subtyping::Constraints.empty
                )

                if result.failure?
                  typing.add_error(Errors::ReturnTypeMismatch.new(node: node,
                                                                  expected: method_context.return_type,
                                                                  actual: value_type,
                                                                  result: result))
                end
              end
            end

            typing.add_typing(node, Types.any)
          end

        when :break
          value = node.children[0]

          if break_context
            case
            when value && break_context.break_type
              check(value, break_context.break_type) do |break_type, actual_type, result|
                typing.add_error Errors::BreakTypeMismatch.new(node: node,
                                                               expected: break_type,
                                                               actual: actual_type,
                                                               result: result)
              end
            when !value
              # ok
            else
              synthesize(value) if value
              typing.add_error Errors::UnexpectedJumpValue.new(node: node)
            end
          else
            synthesize(value)
            typing.add_error Errors::UnexpectedJump.new(node: node)
          end

          typing.add_typing(node, Types.any)

        when :next
          value = node.children[0]

          if break_context
            case
            when value && break_context.next_type
              check(value, break_context.next_type) do |break_type, actual_type, result|
                typing.add_error Errors::BreakTypeMismatch.new(node: node,
                                                               expected: break_type,
                                                               actual: actual_type,
                                                               result: result)
              end
            when !value
              # ok
            else
              synthesize(value) if value
              typing.add_error Errors::UnexpectedJumpValue.new(node: node)
            end
          else
            synthesize(value)
            typing.add_error Errors::UnexpectedJump.new(node: node)
          end

          typing.add_typing(node, Types.any)

        when :arg, :kwarg, :procarg0
          yield_self do
            var = node.children[0]
            type = type_env.get(lvar: var.name) do
              fallback_to_any node
            end
            typing.add_typing(node, type)
          end

        when :optarg, :kwoptarg
          yield_self do
            var = node.children[0]
            rhs = node.children[1]
            type_assignment(var, rhs, node)
          end

        when :restarg
          yield_self do
            var = node.children[0]
            type = type_env.get(lvar: var.name) do
              typing.add_error Errors::FallbackAny.new(node: node)
              Types.array_instance(Types.any)
            end

            typing.add_typing(node, type)
          end

        when :int
          typing.add_typing(node, AST::Types::Name.new_instance(name: "::Integer"))

        when :float
          typing.add_typing(node, AST::Types::Name.new_instance(name: "::Float"))

        when :nil
          typing.add_typing(node, Types.any)

        when :sym
          typing.add_typing(node, Types.symbol_instance)

        when :str
          typing.add_typing(node, Types.string_instance)

        when :true, :false
          typing.add_typing(node, AST::Types::Name.new_interface(name: :_Boolean))

        when :hash
          each_child_node(node) do |pair|
            raise "Unexpected non pair: #{pair.inspect}" unless pair.type == :pair
            each_child_node(pair) do |e|
              synthesize(e)
            end
          end

          typing.add_typing(node, Types.any)

        when :dstr
          each_child_node(node) do |child|
            synthesize(child)
          end

          typing.add_typing(node, Types.string_instance)

        when :dsym
          each_child_node(node) do |child|
            synthesize(child)
          end

          typing.add_typing(node, Types.symbol_instance)

        when :class
          yield_self do
            for_class(node).tap do |constructor|
              constructor.synthesize(node.children[2]) if node.children[2]

              if constructor.module_context&.implement_name && !namespace_module?(node)
                constructor.validate_method_definitions(node, constructor.module_context.implement_name)
              end
            end

            typing.add_typing(node, Types.nil_instance)
          end

        when :module
          yield_self do
            for_module(node).yield_self do |constructor|
              constructor.synthesize(node.children[1]) if node.children[1]

              if constructor.module_context&.implement_name && !namespace_module?(node)
                constructor.validate_method_definitions(node, constructor.module_context.implement_name)
              end
            end

            typing.add_typing(node, Types.nil_instance)
          end

        when :self
          if self_type
            typing.add_typing(node, self_type)
          else
            fallback_to_any node
          end

        when :const
          const_name = ModuleName.from_node(node)
          if const_name
            type = type_env.get(const: const_name) do
              fallback_to_any node
            end
            typing.add_typing node, type
          else
            fallback_to_any node
          end

        when :casgn
          yield_self do
            const_name = ModuleName.from_node(node)
            if const_name
              value_type = synthesize(node.children.last)
              type = type_env.assign(const: const_name, type: value_type) do |error|
                case error
                when Subtyping::Result::Failure
                  const_type = type_env.get(const: const_name)
                  typing.add_error(Errors::IncompatibleAssignment.new(node: node,
                                                                      lhs_type: const_type,
                                                                      rhs_type: value_type,
                                                                      result: error))
                when nil
                  typing.add_error(Errors::UnknownConstantAssigned.new(node: node, type: value_type))
                end
              end

              typing.add_typing(node, type)
            else
              synthesize(node.children.last)
              fallback_to_any(node)
            end
          end

        when :yield
          if method_context&.method_type
            if method_context.block_type
              block_type = method_context.block_type
              block_type.params.flat_unnamed_params.map(&:last).zip(node.children).each do |(type, node)|
                if node && type
                  check(node, type) do |_, rhs_type, result|
                    typing.add_error(Errors::IncompatibleAssignment.new(node: node,
                                                                        lhs_type: type,
                                                                        rhs_type: rhs_type,
                                                                        result: result))
                  end
                end
              end

              typing.add_typing(node, block_type.return_type)
            else
              typing.add_error(Errors::UnexpectedYield.new(node: node))
              fallback_to_any node
            end
          else
            fallback_to_any node
          end

        when :zsuper
          yield_self do
            if method_context&.method
              if method_context.super_method
                types = method_context.super_method.types.map(&:return_type)
                typing.add_typing(node, union_type(*types))
              else
                typing.add_error(Errors::UnexpectedSuper.new(node: node, method: method_context.name))
                fallback_to_any node
              end
            else
              fallback_to_any node
            end
          end

        when :array
          yield_self do
            if node.children.empty?
              typing.add_typing(node, Types.array_instance(Types.any))
            else
              types = node.children.flat_map do |e|
                if e.type == :splat
                  Steep.logger.info "Typing of splat in array is incompatible with Ruby; it does not use #to_a method"
                  synthesize(e.children.first).yield_self do |type|
                    case type
                    when AST::Types::Union
                      type.types
                    else
                      [type]
                    end
                  end.map do |type|
                    case
                    when type.is_a?(AST::Types::Name) && type.name.is_a?(TypeName::Instance) && type.name.name == ModuleName.new(name: "Array", absolute: true)
                      type.args.first
                    when type.is_a?(AST::Types::Name) && type.name.is_a?(TypeName::Instance) && type.name.name == ModuleName.new(name: "Range", absolute: true)
                      type.args.first
                    else
                      type
                    end
                  end
                else
                  [synthesize(e)]
                end
              end

              typing.add_typing(node, Types.array_instance(AST::Types::Union.build(types: types)))
            end
          end

        when :and
          types = each_child_node(node).map {|child| synthesize(child) }
          typing.add_typing(node, types.last)

        when :or
          types = each_child_node(node).map {|child| synthesize(child) }
          type = union_type(*types)
          typing.add_typing(node, type)

        when :if
          cond, true_clause, false_clause = node.children
          synthesize cond
          if true_clause
            true_type, true_env = for_branch(true_clause).yield_self do |constructor|
              type = constructor.synthesize(true_clause)
              [type, constructor.type_env]
            end
          end
          if false_clause
            false_type, false_env = for_branch(false_clause).yield_self do |constructor|
              type = constructor.synthesize(false_clause)
              [type, constructor.type_env]
            end
          end

          type_env.join!([true_env, false_env].compact)
          typing.add_typing(node, union_type(true_type, false_type))

        when :case
          yield_self do
            cond, *whens = node.children

            if cond
              cond_type = synthesize(cond)
              if cond.type == :lvar && cond_type.is_a?(AST::Types::Union)
                var_name = cond.children.first.name
                var_types = cond_type.types.dup
              end
            end

            pairs = whens.each.with_object([]) do |clause, pairs|
              if clause&.type == :when
                test_types = clause.children.take(clause.children.size - 1).map do |child|
                  synthesize(child)
                end

                if (body = clause.children.last)
                  if var_name && var_types && test_types.all? {|type| type.is_a?(AST::Types::Name) && type.name.is_a?(TypeName::Class) && type.args.empty? }
                    var_types_in_body = test_types.flat_map {|test_type|
                      filtered_types = var_types.select {|var_type| var_type.name.name == test_type.name.name }
                      if filtered_types.empty?
                        test_type.instance_type
                      else
                        filtered_types
                      end
                    }
                    var_types.reject! {|type|
                      var_types_in_body.any? {|test_type|
                        test_type.name.name == type.name.name
                      }
                    }

                    type_case_override = { var_name => union_type(*var_types_in_body) }
                  else
                    type_case_override = nil
                  end

                  for_branch(body, type_case_override: type_case_override).yield_self do |body_construction|
                    type = body_construction.synthesize(body)
                    pairs << [type, body_construction.type_env]
                  end
                else
                  pairs << [Types.any, nil]
                end
              else
                if clause
                  if var_types
                    if !var_types.empty?
                      type_case_override = { var_name => union_type(*var_types) }
                    else
                      typing.add_error Errors::ElseOnExhaustiveCase.new(node: node, type: cond_type)
                      type_case_override = { var_name => AST::Types::Any.new }
                    end
                  end

                  for_branch(clause, type_case_override: type_case_override).yield_self do |body_construction|
                    type = body_construction.synthesize(clause)
                    pairs << [type, body_construction.type_env]
                  end
                end
              end
            end

            types = pairs.map(&:first)
            envs = pairs.map(&:last)

            type_env.join!(envs.compact)
            typing.add_typing(node, union_type(*types))
          end

        when :rescue
          yield_self do
            body, *resbodies, else_node = node.children
            body_type = synthesize(body) if body

            resbody_pairs = resbodies.map do |resbody|
              resbody_construction = for_branch(resbody)
              [resbody_construction.synthesize(resbody), resbody_construction.type_env]
            end
            resbody_types, resbody_envs = resbody_pairs.transpose

            if else_node
              else_construction = for_branch(else_node)
              else_type = else_construction.synthesize(else_node)
              else_env = else_construction.type_env
            end

            type_env.join!([*resbody_envs, else_env].compact)

            types = [body_type, *resbody_types, else_type].compact
            typing.add_typing(node, union_type(*types))
          end

        when :resbody
          yield_self do
            klasses, asgn, body = node.children
            synthesize(klasses) if klasses
            synthesize(asgn) if asgn
            body_type = synthesize(body) if body
            typing.add_typing(node, body_type)
          end

        when :ensure
          yield_self do
            body, ensure_body = node.children
            body_type = synthesize(body) if body
            synthesize(ensure_body) if ensure_body
            typing.add_typing(node, union_type(body_type))
          end

        when :masgn
          type_masgn(node)

        when :while, :while_post, :until, :until_post
          yield_self do
            cond, body = node.children

            synthesize(cond)

            if body
              for_loop = for_branch(body).with(break_context: BreakContext.new(break_type: nil, next_type: nil))
              for_loop.synthesize(body)
              type_env.join!([for_loop.type_env])
            end

            typing.add_typing(node, Types.any)
          end

        when :irange, :erange
          types = node.children.map {|n| synthesize(n) }
          type = Types.range_instance(union_type(*types))
          typing.add_typing(node, type)

        when :regexp
          each_child_node(node) do |child|
            synthesize(child)
          end

          typing.add_typing(node, AST::Types::Name.new_instance(name: "::Regexp"))

        when :regopt
          # ignore
          typing.add_typing(node, Types.any)

        when :nth_ref, :back_ref
          typing.add_typing(node, Types.string_instance)

        when :or_asgn, :and_asgn
          yield_self do
            _, rhs = node.children
            rhs_type = synthesize(rhs)
            typing.add_typing(node, rhs_type)
          end

        when :defined?
          each_child_node(node) do |child|
            synthesize(child)
          end

          typing.add_typing(node, Types.any)

        when :gvasgn
          yield_self do
            name, rhs = node.children
            type = checker.builder.signatures.find_gvar(name)&.type

            if type
              check(rhs, type) do |_, rhs_type, result|
                typing.add_error(Errors::IncompatibleAssignment.new(node: node,
                                                                    lhs_type: type,
                                                                    rhs_type: rhs_type,
                                                                    result: result))
              end
            else
              synthesize(rhs)
              fallback_to_any node
            end
          end

        when :gvar
          yield_self do
            name = node.children.first
            type = checker.builder.signatures.find_gvar(name)&.type

            if type
              typing.add_typing(node, type)
            else
              fallback_to_any node
            end
          end

        when :splat
          yield_self do
            Steep.logger.error "Unexpected splat: splat have to be in an array"
          end

          each_child_node node do |child|
            synthesize(child)
          end

          fallback_to_any node

        else
          raise "Unexpected node: #{node.inspect}, #{node.location.expression}"
        end
      end
    end

    def check(node, type)
      type_ = synthesize(node)

      result = checker.check(
        Subtyping::Relation.new(sub_type: type_,
                                super_type: type),
        constraints: Subtyping::Constraints.empty
      )
      if result.failure?
        yield(type, type_, result)
      end
    end

    def type_assignment(var, rhs, node)
      if rhs
        rhs_type = synthesize(rhs)
        node_type = assign_type_to_variable(var, rhs_type, node)
        typing.add_typing(node, node_type)
      else
        raise
        lhs_type = variable_type(var)

        if lhs_type
          typing.add_var_type(var, lhs_type)
          typing.add_typing(node, lhs_type)
          var_types[var] = lhs_type
        else
          typing.add_var_type(var, Types.any)
          fallback_to_any node
          var_types[var] = Types.any
        end
      end
    end

    def assign_type_to_variable(var, type, node)
      name = var.name
      type_env.assign(lvar: name, type: type) do |result|
        var_type = type_env.get(lvar: name)
        typing.add_error(Errors::IncompatibleAssignment.new(node: node,
                                                            lhs_type: var_type,
                                                            rhs_type: type,
                                                            result: result))
      end
    end

    def type_ivasgn(name, rhs, node)
      rhs_type = synthesize(rhs)
      ivar_type = type_env.assign(ivar: name, type: rhs_type) do |error|
        case error
        when Subtyping::Result::Failure
          type = type_env.get(ivar: name)
          typing.add_error(Errors::IncompatibleAssignment.new(node: node,
                                                              lhs_type: type,
                                                              rhs_type: rhs_type,
                                                              result: error))
        when nil
          fallback_to_any node
        end
      end
      typing.add_typing(node, ivar_type)
    end

    def type_masgn(node)
      lhs, rhs = node.children
      rhs_type = synthesize(rhs)

      case
      when rhs.type == :array && lhs.children.all? {|a| a.type == :lvasgn || a.type == :ivasgn } && lhs.children.size == rhs.children.size
        pairs = lhs.children.zip(rhs.children)
        pairs.each do |(l, r)|
          case
          when l.type == :lvasgn
            type_assignment(l.children.first, r, l)
          when l.type == :ivasgn
            type_ivasgn(l.children.first, r, l)
          end
        end

        typing.add_typing(node, rhs_type)

      when rhs_type.is_a?(AST::Types::Any)
        fallback_to_any(node)

      when rhs_type.is_a?(AST::Types::Name) && rhs_type.name.is_a?(TypeName::Instance) && rhs_type.name.name == ModuleName.new(name: "Array", absolute: true)
        element_type = rhs_type.args.first

        lhs.children.each do |assignment|
          case assignment.type
          when :lvasgn
            assign_type_to_variable(assignment.children.first, element_type, assignment)
          when :ivasgn
            assignment.children.first.yield_self do |ivar|
              type_env.assign(ivar: ivar, type: element_type) do |error|
                case error
                when Subtyping::Result::Failure
                  type = type_env.get(ivar: ivar)
                  typing.add_error(Errors::IncompatibleAssignment.new(node: assignment,
                                                                      lhs_type: type,
                                                                      rhs_type: element_type,
                                                                      result: error))
                when nil
                  fallback_to_any node
                end
              end
            end
          end
        end

        typing.add_typing node, rhs_type

      when rhs_type.is_a?(AST::Types::Union) &&
        rhs_type.types.all? {|type| type.is_a?(AST::Types::Name) && type.name.is_a?(TypeName::Instance) && type.name.name == ModuleName.new(name: "Array", absolute: true) }

        types = rhs_type.types.flat_map do |type|
          type.args.first
        end

        element_type = AST::Types::Union.build(types: types)

        lhs.children.each do |assignment|
          case assignment.type
          when :lvasgn
            assign_type_to_variable(assignment.children.first, element_type, assignment)
          when :ivasgn
            assignment.children.first.yield_self do |ivar|
              type_env.assign(ivar: ivar, type: element_type) do |error|
                case error
                when Subtyping::Result::Failure
                  type = type_env.get(ivar: ivar)
                  typing.add_error(Errors::IncompatibleAssignment.new(node: assignment,
                                                                      lhs_type: type,
                                                                      rhs_type: element_type,
                                                                      result: error))
                when nil
                  fallback_to_any node
                end
              end
            end
          end
        end

        typing.add_typing node, rhs_type

      else
        Steep.logger.error("Unsupported masgn: #{rhs.type} (#{rhs_type})")
        fallback_to_any(node)
      end
    end

    def type_send(node, send_node:, block_params:, block_body:)
      receiver, method_name, *arguments = send_node.children
      receiver_type = receiver ? synthesize(receiver) : self_type
      arguments.each do |arg|
        if arg.type == :splat
          synthesize(arg.children.first)
        else
          synthesize(arg)
        end
      end

      case receiver_type
      when AST::Types::Any
        typing.add_typing node, Types.any

      when nil
        fallback_to_any node

      else
        begin
          interface = checker.resolve(receiver_type, with_initialize: false)
          method = interface.methods[method_name]

          if method
            args = TypeInference::SendArgs.from_nodes(arguments)
            return_type_or_error = type_method_call(node,
                                                    method: method,
                                                    args: args,
                                                    block_params: block_params,
                                                    block_body: block_body)

            if return_type_or_error.is_a?(Errors::Base)
              fallback_to_any node do
                return_type_or_error
              end
            else
              typing.add_typing node, return_type_or_error
            end
          else
            fallback_to_any node do
              Errors::NoMethod.new(node: node, method: method_name, type: receiver_type)
            end
          end
        rescue Subtyping::Check::CannotResolveError
          fallback_to_any node do
            Errors::NoMethod.new(node: node, method: method_name, type: receiver_type)
          end
        end
      end
    end

    def type_method_call(node, method:, args:, block_params:, block_body:)
      results = method.types.map do |method_type|
        Steep.logger.tagged method_type.location&.source do
          arg_pairs = args.zip(method_type.params)

          if arg_pairs
            try_method_type(node,
                            method_type: method_type,
                            arg_pairs: arg_pairs,
                            block_params: block_params,
                            block_body: block_body)
          else
            Steep.logger.debug(node.inspect)
            Errors::IncompatibleArguments.new(node: node, method_type: method_type)
          end
        end
      end

      if results.all? {|result| result.is_a?(Errors::Base) }
        results.first
      else
        results.find do |result|
          !result.is_a?(Errors::Base)
        end
      end
    end

    def try_method_type(node, method_type:, arg_pairs:, block_params:, block_body:)
      fresh_types = method_type.type_params.map {|x| AST::Types::Var.fresh(x) }
      fresh_vars = Set.new(fresh_types.map(&:name))
      instantiation = Interface::Substitution.build(method_type.type_params, fresh_types)

      method_type.instantiate(instantiation).yield_self do |method_type|
        constraints = Subtyping::Constraints.new(unknowns: fresh_types.map(&:name))
        variance = Subtyping::VariableVariance.from_method_type(method_type)
        occurence = Subtyping::VariableOccurence.from_method_type(method_type)

        arg_pairs.each do |(arg_node, param_type)|
          relation = Subtyping::Relation.new(
            sub_type: typing.type_of(node: arg_node),
            super_type: param_type.subst(instantiation)
          )

          checker.check(relation, constraints: constraints).else do |result|
            return Errors::ArgumentTypeMismatch.new(
              node: arg_node,
              expected: relation.super_type,
              actual: relation.sub_type
            )
          end
        end

        if method_type.block && block_params
          block_annotations = source.annotations(block: node)

          params = TypeInference::BlockParams.from_node(block_params, annotations: block_annotations)
          block_param_pairs = params.zip(method_type.block.params)

          unless block_param_pairs
            return Errors::IncompatibleBlockParameters.new(
              node: node,
              method_type: method_type
            )
          end

          block_param_pairs.each do |param, type|
            if param.type
              relation = Subtyping::Relation.new(
                sub_type: type,
                super_type: absolute_type(param.type)
              )

              checker.check(relation, constraints: constraints).else do |result|
                return Errors::BlockParameterTypeMismatch.new(
                  node: param.node,
                  expected: type,
                  actual: param.type
                )
              end
            end
          end

          if block_annotations.block_type
            relation = Subtyping::Relation.new(
              sub_type: absolute_type(block_annotations.block_type),
              super_type: method_type.block.return_type
            )

            checker.check(relation, constraints: constraints).else do |result|
              typing.add_error Errors::BlockTypeMismatch.new(node: node,
                                                             expected: method_type.block.return_type,
                                                             actual: absolute_type(block_annotations.block_type),
                                                             result: result)
            end
          end
        end

        case
        when method_type.block && block_params && block_body
          Steep.logger.debug "block is okay: method_type=#{method_type}"
          Steep.logger.debug "Constraints = #{constraints}"

          begin
            method_type.subst(constraints.solution(checker, variance: variance, variables: occurence.params)).yield_self do |method_type|
              block_annotations = source.annotations(block: node)

              params = TypeInference::BlockParams.from_node(block_params, annotations: block_annotations)
              block_param_pairs = params.zip(method_type.block.params)

              block_type_env = type_env.dup.yield_self do |env|
                block_param_pairs.each do |param, type|
                  if param.type
                    env.set(lvar: param.var.name, type: absolute_type(param.type))
                  else
                    env.set(lvar: param.var.name, type: absolute_type(type))
                  end
                end

                env.with_annotations(
                  lvar_types: block_annotations.var_types.transform_values {|annot| absolute_type(annot.type) },
                  ivar_types: block_annotations.ivar_types.transform_values {|type| absolute_type(type) },
                  const_types: block_annotations.const_types.transform_values {|type| absolute_type(type) }
                )
              end

              return_type = if block_annotations.break_type
                              union_type(method_type.return_type, absolute_type(block_annotations.break_type))
                            else
                              method_type.return_type
                            end
              Steep.logger.debug("return_type = #{return_type}")

              block_context = BlockContext.new(body_type: absolute_type(block_annotations.block_type))
              Steep.logger.debug("block_context { body_type: #{block_context.body_type} }")

              break_context = BreakContext.new(
                break_type: absolute_type(block_annotations.break_type) || method_type.return_type,
                next_type: absolute_type(block_annotations.block_type)
              )
              Steep.logger.debug("break_context { type: #{absolute_type(break_context.break_type)} }")

              for_block = self.class.new(
                checker: checker,
                source: source,
                annotations: annotations + block_annotations,
                type_env: block_type_env,
                block_context: block_context,
                typing: typing,
                method_context: method_context,
                module_context: module_context,
                self_type: absolute_type(block_annotations.self_type) || self_type,
                break_context: break_context
              )

              each_child_node(block_params) do |p|
                for_block.synthesize(p)
              end

              block_body_type = for_block.synthesize(block_body)

              unless method_type.block.return_type.is_a?(AST::Types::Void)
                result = checker.check(Subtyping::Relation.new(
                  sub_type: block_annotations.block_type || block_body_type,
                  super_type: method_type.block.return_type
                ), constraints: constraints)

                if result.success?
                  return_type.subst(constraints.solution(checker, variance: variance, variables: fresh_vars))
                else
                  typing.add_error Errors::BlockTypeMismatch.new(node: node,
                                                                 expected: method_type.block.return_type,
                                                                 actual: block_annotations.block_type || block_body_type,
                                                                 result: result)
                  return_type
                end
              else
                return_type
              end
            end

          rescue Subtyping::Constraints::UnsatisfiableConstraint => exn
            typing.add_error Errors::UnsatisfiableConstraint.new(node: node,
                                                                 method_type: method_type,
                                                                 var: exn.var,
                                                                 sub_type: exn.sub_type,
                                                                 super_type: exn.super_type,
                                                                 result: exn.result
            )
            fallback_any_rec node
          end

        when !method_type.block && !block_params && !block_body
          # OK, without block
          method_type.subst(constraints.solution(checker, variance: variance, variables: fresh_vars)).return_type

        when !method_type.block && block_params && block_body
          Errors::UnexpectedBlockGiven.new(
            node: node,
            method_type: method_type
          )

        when method_type.block && !block_params && !block_body
          Errors::RequiredBlockMissing.new(
            node: node,
            method_type: method_type
          )

        else
          raise "Unexpected case condition"
        end
      end
    end

    def each_child_node(node)
      if block_given?
        node.children.each do |child|
          if child.is_a?(::AST::Node)
            yield child
          end
        end
      else
        enum_for :each_child_node, node
      end
    end

    def test_args(params:, arguments:)
      params.each_missing_argument arguments do |_|
        return nil
      end

      params.each_extra_argument arguments do |_|
        return nil
      end

      params.each_missing_keyword arguments do |_|
        return nil
      end

      params.each_extra_keyword arguments do |_|
        return nil
      end

      self.class.argument_typing_pairs(params: params, arguments: arguments.dup)
    end

    def applicable_args?(params:, arguments:)
      params.each_missing_argument arguments do |_|
        return false
      end

      params.each_extra_argument arguments do |_|
        return false
      end

      params.each_missing_keyword arguments do |_|
        return false
      end

      params.each_extra_keyword arguments do |_|
        return false
      end

      all_args = arguments.dup

      self.class.argument_typing_pairs(params: params, arguments: arguments.dup).each do |(param_type, argument)|
        all_args.delete_if {|a| a.equal?(argument) }

        check(argument, param_type) do |_, _|
          return false
        end
      end

      all_args.each do |arg|
        synthesize(arg)
      end

      true
    end

    def self.block_param_typing_pairs(param_types: , param_nodes:)
      pairs = []

      param_types.required.each.with_index do |type, index|
        if (param = param_nodes[index])
          pairs << [param, type]
        end
      end

      pairs
    end

    def self.argument_typing_pairs(params:, arguments:)
      keywords = {}
      unless params.required_keywords.empty? && params.optional_keywords.empty? && !params.rest_keywords
        # has keyword args
        last_arg = arguments.last
        if last_arg&.type == :hash
          arguments.pop

          last_arg.children.each do |elem|
            case elem.type
            when :pair
              key, value = elem.children
              if key.type == :sym
                name = key.children[0]

                keywords[name] = value
              end
            end
          end
        end
      end

      pairs = []

      params.flat_unnamed_params.each do |param_type|
        arg = arguments.shift
        pairs << [param_type.last, arg] if arg
      end

      if params.rest
        arguments.each do |arg|
          pairs << [params.rest, arg]
        end
      end

      params.flat_keywords.each do |name, type|
        arg = keywords.delete(name)
        if arg
          pairs << [type, arg]
        end
      end

      if params.rest_keywords
        keywords.each_value do |arg|
          pairs << [params.rest_keywords, arg]
        end
      end

      pairs
    end

    def self.parameter_types(nodes, type)
      nodes = nodes.dup

      env = {}

      type.params.required.each do |type|
        a = nodes.first
        if a&.type == :arg
          env[a.children.first] = type
          nodes.shift
        else
          break
        end
      end

      type.params.optional.each do |type|
        a = nodes.first

        if a&.type == :optarg
          env[a.children.first] = type
          nodes.shift
        else
          break
        end
      end

      if type.params.rest
        a = nodes.first
        if a&.type == :restarg
          env[a.children.first] = Types.array_instance(type.params.rest)
          nodes.shift
        end
      end

      nodes.each do |node|
        if node.type == :kwarg
          name = node.children[0]
          ty = type.params.required_keywords[name.name]
          env[name] = ty if ty
        end

        if node.type == :kwoptarg
          name = node.children[0]
          ty = type.params.optional_keywords[name.name]
          env[name] = ty if ty
        end

        if node.type == :kwrestarg
          ty = type.params.rest_keywords
          if ty
            env[node.children[0]] = Types::Name.instance(
              name: "::Hash",
              params: [
                Types::Name.instance(name: :Symbol),
                ty
              ]
            )
          end
        end
      end

      env
    end

    def self.valid_parameter_env?(env, nodes, params)
      env.size == nodes.size && env.size == params.size
    end

    def current_namespace
      module_context&.current_namespace
    end

    def nested_namespace(new)
      case
      when !new.simple?
        current_namespace
      when current_namespace
        current_namespace + new
      else
        new.absolute!
      end
    end

    def absolute_name(module_name)
      if current_namespace
        current_namespace + module_name
      else
        module_name.absolute!
      end
    end

    def absolute_type(type)
      if type
        checker.builder.absolute_type(type, current: current_namespace)
      end
    end

    def union_type(*types)
      types_ = checker.compact(types.compact)
      AST::Types::Union.build(types: types_)
    end

    def validate_method_definitions(node, module_name)
      signature = checker.builder.signatures.find_class_or_module(module_name.name)

      signature.members.each do |member|
        if member.is_a?(AST::Signature::Members::Method)
          if member.instance_method?
            case
            when module_context.defined_instance_methods.include?(member.name)
              # ok
            when annotations.dynamics[member.name]&.instance_method?
              # ok
            else
              typing.add_error Errors::MethodDefinitionMissing.new(node: node,
                                                                   module_name: module_name.name,
                                                                   kind: :instance,
                                                                   missing_method: member.name)
            end
          end

          if member.module_method?
            case
            when module_context.defined_module_methods.include?(member.name)
              # ok
            when annotations.dynamics[member.name]&.module_method?
              # ok
            else
              typing.add_error Errors::MethodDefinitionMissing.new(node: node,
                                                                   module_name: module_name.name,
                                                                   kind: :module,
                                                                   missing_method: member.name)
            end
          end
        end
      end

      annotations.dynamics.each do |method_name, annotation|
        method_signature = signature.members.find {|sig| sig.is_a?(AST::Signature::Members::Method) && sig.name == method_name }

        case
        when annotation.module_method? && method_signature&.module_method?
          # ok
        when annotation.instance_method? && method_signature&.instance_method?
          # ok
        else
          typing.add_error Errors::UnexpectedDynamicMethod.new(node: node,
                                                               module_name: module_name.name,
                                                               method_name: method_name)
        end
      end
    end

    def flatten_const_name(node)
      path = []

      while node
        case node.type
        when :const, :casgn
          path.unshift(node.children[1])
          node = node.children[0]
        when :cbase
          path.unshift("")
          break
        else
          return nil
        end
      end

      path.join("::").to_sym
    end

    def fallback_to_any(node)
      if block_given?
        typing.add_error yield
      else
        typing.add_error Errors::FallbackAny.new(node: node)
      end

      typing.add_typing node, Types.any
    end

    def self_class?(node)
      node.type == :send && node.children[0]&.type == :self && node.children[1] == :class
    end

    def namespace_module?(node)
      nodes = case node.type
              when :class, :module
                node.children.last&.yield_self {|child|
                  if child.type == :begin
                    child.children
                  else
                    [child]
                  end
                } || []
              else
                return false
              end

      !nodes.empty? && nodes.all? {|child| child.type == :class || child.type == :module }
    end

    def fallback_any_rec(node)
      fallback_to_any(node) unless typing.has_type?(node)

      each_child_node(node) do |child|
        fallback_any_rec(child)
      end

      typing.type_of(node: node)
    end
  end
end

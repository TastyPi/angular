import 'package:analyzer/analyzer.dart' hide Directive;
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/element/visitor.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/src/dart/analysis/results.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';
import 'package:source_span/source_span.dart';
import 'package:angular/src/compiler/analyzed_class.dart';
import 'package:angular/src/compiler/compile_metadata.dart';
import 'package:angular/src/compiler/expression_parser/ast.dart' as ast;
import 'package:angular/src/compiler/offline_compiler.dart';
import 'package:angular/src/compiler/output/convert.dart';
import 'package:angular/src/compiler/output/output_ast.dart' as o;
import 'package:angular/src/compiler/view_compiler/property_binder.dart'
    show isPrimitiveTypeName;
import 'package:angular/src/core/change_detection/constants.dart';
import 'package:angular/src/core/metadata.dart';
import 'package:angular/src/core/metadata/lifecycle_hooks.dart';
import 'package:angular/src/source_gen/common/annotation_matcher.dart';
import 'package:angular/src/source_gen/common/url_resolver.dart';
import 'package:angular_compiler/angular_compiler.dart';
import 'package:angular_compiler/cli.dart';

import 'compile_metadata.dart';
import 'dart_object_utils.dart';
import 'pipe_visitor.dart';

const String _visibilityProperty = 'visibility';
const _statefulDirectiveFields = [
  'exportAs',
];

AngularArtifacts findComponentsAndDirectives(
    LibraryReader library, FindComponentsExceptionHandler exceptionHandler) {
  var componentVisitor = _NormalizedComponentVisitor(library, exceptionHandler);
  library.element.accept(componentVisitor);
  return AngularArtifacts(
    componentVisitor.components,
    componentVisitor.directives,
  );
}

class _NormalizedComponentVisitor extends RecursiveElementVisitor<Null> {
  final List<NormalizedComponentWithViewDirectives> components = [];
  final List<CompileDirectiveMetadata> directives = [];
  final LibraryReader _library;

  final FindComponentsExceptionHandler _exceptionHandler;

  _NormalizedComponentVisitor(this._library, this._exceptionHandler);

  @override
  Null visitClassElement(ClassElement element) {
    final directive =
        element.accept(_ComponentVisitor(_library, _exceptionHandler));
    if (directive != null) {
      if (directive.isComponent) {
        final directives = _visitDirectives(element);
        final directiveTypes = _visitDirectiveTypes(element);
        final pipes = _visitPipes(element);
        _errorOnUnusedDirectiveTypes(
            element, directives, directiveTypes, _exceptionHandler);
        components.add(NormalizedComponentWithViewDirectives(
          directive,
          directives,
          directiveTypes,
          pipes,
        ));
      } else {
        directives.add(directive);
      }
    }
    return null;
  }

  @override
  Null visitFunctionElement(FunctionElement element) {
    final directive =
        element.accept(_ComponentVisitor(_library, _exceptionHandler));
    if (directive != null) {
      directives.add(directive);
    }
    return null;
  }

  List<CompileDirectiveMetadata> _visitDirectives(ClassElement element) {
    final values = _getResolvedArgumentsOrFail(element, 'directives');
    return visitAll(values, (value) {
      return typeDeclarationOf(value)
          ?.accept(_ComponentVisitor(_library, _exceptionHandler));
    });
  }

  List<CompileTypedMetadata> _visitDirectiveTypes(ClassElement element) {
    final values = _getResolvedArgumentsOrFail(element, 'directiveTypes');
    final typedReader = TypedReader(element);
    final directiveTypes = <CompileTypedMetadata>[];
    for (final value in values) {
      directiveTypes.add(_typeMetadataFrom(typedReader.parse(value)));
    }
    return directiveTypes;
  }

  List<CompilePipeMetadata> _visitPipes(ClassElement element) {
    final values = _getResolvedArgumentsOrFail(element, 'pipes');
    return visitAll(values, (value) {
      return typeDeclarationOf(value)?.accept(PipeVisitor(_library));
    });
  }

  /// Returns the arguments assigned to [field], ensuring they're resolved.
  ///
  /// This will immediately fail compilation and inform the user if any
  /// arguments can't be resolved. Failing here avoids misleading errors that
  /// arise from unresolved arguments later on in compilation.
  ///
  /// This assumes [field] expects a list of arguments.
  List<DartObject> _getResolvedArgumentsOrFail(
    ClassElement element,
    String field,
  ) {
    final annotation = element.metadata.firstWhere(safeMatcher(isComponent));
    final values = coerceList(annotation.computeConstantValue(), field);
    if (values.isEmpty) {
      // Two reasons we got to this point:
      // 1. The list argument was empty or omitted.
      // 2. One or more identifiers in the list were not resolved, potentially
      //    due to missing imports or dependencies.
      //
      // The latter is specifically tricky to debug, because it ends up failing
      // template parsing in a similar way to #1, but a user will look at the
      // code and not see a problem potentially.
      final annotationImpl = annotation as ElementAnnotationImpl;
      for (final argument in annotationImpl.annotationAst.arguments.arguments) {
        if (argument is NamedExpression && argument.name.label.name == field) {
          final values = argument.expression as ListLiteral;
          if (values.elements.isNotEmpty &&
              // Avoid an edge case where all of your entries are just empty
              // lists. Not likely to happen, but might as well check anyway at
              // this point.
              values.elements.every((e) => e.staticType?.isDynamic != false)) {
            // We didn't resolve something.
            _exceptionHandler.handle((UnresolvedExpressionError(
                values.elements.where((e) => e.staticType?.isDynamic != false),
                element,
                annotationImpl.compilationUnit)));
          }
        }
      }
    }
    return values;
  }

  CompileTypedMetadata _typeMetadataFrom(TypedElement typed) {
    final typeLink = typed.typeLink;
    final typeArguments = <o.OutputType>[];
    for (final generic in typeLink.generics) {
      typeArguments.add(fromTypeLink(generic, _library));
    }
    return CompileTypedMetadata(
      typeLink.symbol,
      typeLink.import,
      typeArguments,
      on: typed.on,
    );
  }
}

class _ComponentVisitor
    extends RecursiveElementVisitor<CompileDirectiveMetadata> {
  final _fieldInputs = <String, String>{};
  final _setterInputs = <String, String>{};
  final _inputs = <String, String>{};
  final _inputTypes = <String, CompileTypeMetadata>{};
  final _outputs = <String, String>{};
  final _hostBindings = <String, ast.AST>{};
  final _hostListeners = <String, String>{};
  final _queries = <CompileQueryMetadata>[];
  final _viewQueries = <CompileQueryMetadata>[];

  final LibraryReader _library;
  final FindComponentsExceptionHandler _exceptionHandler;

  /// Whether the component being visited re-implements 'noSuchMethod'.
  bool _implementsNoSuchMethod = false;

  /// Element of the current directive being visited.
  ///
  /// This is used to look up resolved type information.
  ClassElement _directiveClassElement;

  _ComponentVisitor(this._library, this._exceptionHandler);

  @override
  CompileDirectiveMetadata visitClassElement(ClassElement element) {
    final annotationIndex =
        element.metadata.indexWhere(safeMatcher(isDirective));
    if (annotationIndex == -1) return null;
    final annotation = element.metadata[annotationIndex];

    if (element.isPrivate) {
      log.severe('Components and directives must be public: $element');
      return null;
    }
    return _createCompileDirectiveMetadata(
        IndexedAnnotation(element, annotation, annotationIndex));
  }

  @override
  CompileDirectiveMetadata visitFunctionElement(FunctionElement element) {
    final annotation = element.metadata.firstWhere(
      safeMatcherType(Directive),
      orElse: () => null,
    );
    if (annotation == null) return null;
    var invalid = false;
    if (element.isPrivate) {
      log.severe('Functional directives must be public: $element');
      invalid = true;
    }
    if (!element.returnType.isVoid) {
      log.severe('Functional directives must return void: $element');
      invalid = true;
    }
    final annotationValue = annotation.computeConstantValue();
    for (var field in _statefulDirectiveFields) {
      if (!annotationValue.getField(field).isNull) {
        log.severe("Functional directives don't support '$field': $element");
        invalid = true;
      }
    }
    final visibility = coerceEnum(
      annotationValue,
      _visibilityProperty,
      Visibility.values,
    );
    if (visibility != Visibility.local) {
      log.severe('Functional directives must be visibility: Visibility.local');
      invalid = true;
    }
    if (invalid) return null;
    final type = element.accept(CompileTypeMetadataVisitor(_library));
    final selector = coerceString(annotationValue, 'selector');
    return CompileDirectiveMetadata(
      type: type,
      originType: type,
      metadataType: CompileDirectiveMetadataType.FunctionalDirective,
      selector: selector,
      inputs: const {},
      inputTypes: const {},
      outputs: const {},
      hostBindings: const {},
      hostListeners: const {},
      providers: _extractProviders(annotationValue, 'providers'),
    );
  }

  @override
  CompileDirectiveMetadata visitFieldElement(FieldElement element) {
    super.visitFieldElement(element);
    _visitClassMember(
      element,
      isGetter: element.getter != null,
      isSetter: element.setter != null,
    );
    return null;
  }

  @override
  CompileDirectiveMetadata visitPropertyAccessorElement(
    PropertyAccessorElement element,
  ) {
    super.visitPropertyAccessorElement(element);
    _visitClassMember(
      element,
      isGetter: element.isGetter,
      isSetter: element.isSetter,
    );
    return null;
  }

  void _visitClassMember(
    Element element, {
    bool isGetter = false,
    bool isSetter = false,
  }) {
    for (var annotationIndex = 0;
        annotationIndex < element.metadata.length;
        annotationIndex++) {
      ElementAnnotation annotation = element.metadata[annotationIndex];
      final indexedAnnotation =
          IndexedAnnotation(element, annotation, annotationIndex);
      if (safeMatcherType(Input)(annotation)) {
        if (isSetter && element.isPublic) {
          final isField = element is FieldElement;
          // Resolves specified generic type parameters.
          final setter = _directiveClassElement.type
              .lookUpInheritedSetter(element.displayName);
          final propertyType = setter.parameters.first.type;
          final dynamicType = setter.context.typeProvider.dynamicType;
          // Resolves unspecified or bounded generic type parameters.
          final resolvedType = propertyType.resolveToBound(dynamicType);
          final typeName = getTypeName(resolvedType);
          _addPropertyBindingTo(
              isField ? _fieldInputs : _setterInputs, annotation, element,
              immutableBindings: _inputs);
          if (typeName != null) {
            if (isPrimitiveTypeName(typeName)) {
              _inputTypes[element.displayName] =
                  CompileTypeMetadata(name: typeName);
            } else {
              // Convert any generic type parameters from the input's type to
              // our internal output AST.
              final List<o.OutputType> typeArguments =
                  resolvedType is ParameterizedType
                      ? resolvedType.typeArguments.map(fromDartType).toList()
                      : const [];
              _inputTypes[element.displayName] = CompileTypeMetadata(
                  moduleUrl: moduleUrl(element),
                  name: typeName,
                  typeArguments: typeArguments);
            }
          }
        } else {
          log.severe('@Input can only be used on a public setter or non-final '
              'field, but was found on $element.');
        }
      } else if (safeMatcherType(Output)(annotation)) {
        if (isGetter && element.isPublic) {
          _addPropertyBindingTo(_outputs, annotation, element);
        } else {
          log.severe('@Output can only be used on a public getter or field, '
              'but was found on $element.');
        }
      } else if (safeMatcherTypes(const [
        ContentChildren,
        ContentChild,
      ])(annotation)) {
        if (isSetter && element.isPublic) {
          _queries.add(_getQuery(
            indexedAnnotation,
            // Avoid emitting the '=' part of the setter.
            element.displayName,
            _fieldOrPropertyType(element),
          ));
        } else {
          log.severe('@ContentChild or @ContentChildren can only be used on a '
              'public setter or non-final field, but was found on $element.');
        }
      } else if (safeMatcherTypes(const [
        ViewChildren,
        ViewChild,
      ])(annotation)) {
        if (isSetter && element.isPublic) {
          _viewQueries.add(_getQuery(
            indexedAnnotation,
            // Avoid emitting the '=' part of the setter.
            element.displayName,
            _fieldOrPropertyType(element),
          ));
        } else {
          log.severe('@ViewChild or @ViewChildren can only be used on a public '
              'setter or non-final field, but was found on $element.');
        }
      }
    }
  }

  DartType _fieldOrPropertyType(Element element) {
    if (element is PropertyAccessorElement && element.isSetter) {
      return element.parameters.first.type;
    }
    if (element is FieldElement) {
      return element.type;
    }
    return null;
  }

  List<CompileTokenMetadata> _getSelectors(
      IndexedAnnotation indexedAnnotation, DartObject value) {
    var selector = getField(value, 'selector');
    if (isNull(selector)) {
      _exceptionHandler.handle(ErrorMessageForAnnotation(indexedAnnotation,
          'Missing selector argument for "@${value.type.name}"'));
      return [];
    }
    var selectorString = selector?.toStringValue();
    if (selectorString != null) {
      return selectorString
          .split(',')
          .map((s) => CompileTokenMetadata(value: s))
          .toList();
    }
    var selectorType = selector.toTypeValue();
    if (selectorType == null) {
      // NOTE(deboer): This code is untested and probably unreachable.
      _exceptionHandler.handle(ErrorMessageForAnnotation(
          indexedAnnotation,
          'Only a value of `String` or `Type` for "@${value.type.name}" is '
          'supported'));
      return [];
    }
    return [
      CompileTokenMetadata(
        identifier: CompileIdentifierMetadata(
          name: selectorType.name,
          moduleUrl: moduleUrl(selectorType.element),
        ),
      ),
    ];
  }

  static final _coreIterable = TypeChecker.fromUrl('dart:core#Iterable');
  static final _htmlElement = TypeChecker.fromUrl('dart:html#Element');

  CompileQueryMetadata _getQuery(
    IndexedAnnotation indexedAnnotation,
    String propertyName,
    DartType propertyType,
  ) {
    final value = indexedAnnotation.annotation.computeConstantValue();
    final readType = getField(value, 'read')?.toTypeValue();
    return CompileQueryMetadata(
      selectors: _getSelectors(indexedAnnotation, value),
      descendants: coerceBool(value, 'descendants', defaultTo: false),
      first: coerceBool(value, 'first', defaultTo: false),
      propertyName: propertyName,
      isElementType: propertyType?.element != null &&
              _htmlElement.isAssignableFromType(propertyType) ||
          // A bit imprecise, but this will cover 'Iterable' and 'List'.
          _coreIterable.isAssignableFromType(propertyType) &&
              propertyType is ParameterizedType &&
              _htmlElement
                  .isAssignableFromType(propertyType.typeArguments.first),
      read: readType != null
          ? CompileTokenMetadata(
              identifier: CompileIdentifierMetadata(
                name: readType.displayName,
                moduleUrl: moduleUrl(readType.element),
              ),
            )
          : null,
    );
  }

  void _addHostBinding(Element element, DartObject value) {
    final property = coerceString(
      value,
      'hostPropertyName',
      defaultTo: element.name,
    );
    // Allows using static members for @HostBinding. For example:
    //
    // class Foo {
    //   @HostBinding('title')
    //   static const title = 'Hello';
    // }
    var bindTo = ast.PropertyRead(ast.ImplicitReceiver(), element.name);
    if (element is PropertyAccessorElement && element.isStatic ||
        element is FieldElement && element.isStatic) {
      if (element.enclosingElement != _directiveClassElement) {
        // We do not want to inherit static members.
        // https://github.com/dart-lang/angular/issues/1272
        return;
      }
      var classId = CompileIdentifierMetadata(
          name: _directiveClassElement.name,
          moduleUrl: moduleUrl(_directiveClassElement.library),
          analyzedClass: AnalyzedClass(_directiveClassElement));
      bindTo = ast.PropertyRead(ast.StaticRead(classId), element.name);
    }
    _hostBindings[property] = bindTo;
  }

  void _addHostListener(MethodElement element, DartObject value) {
    var eventName = coerceString(value, 'eventName');
    var methodName = element.name;
    var methodArgs = coerceStringList(value, 'args');
    if (methodArgs.isEmpty && element.parameters.length == 1) {
      // Infer $event.
      methodArgs = const [r'$event'];
    }
    _hostListeners[eventName] = '$methodName(${methodArgs.join(', ')})';
  }

  /// Adds a property binding for [element] to [bindings].
  ///
  /// The property binding maps [element]'s display name to a binding name. By
  /// default, [element]'s name is used as the binding name. However, if
  /// [annotation] has a `bindingPropertyName` field, its value is used instead.
  ///
  /// Property bindings are immutable by default, to prevent derived classes
  /// from overriding inherited binding names. The optional [immutableBindings]
  /// may be provided to restrict a different set of property bindings than
  /// [bindings].
  void _addPropertyBindingTo(
    Map<String, String> bindings,
    ElementAnnotation annotation,
    Element element, {
    Map<String, String> immutableBindings,
  }) {
    final value = annotation.computeConstantValue();
    final propertyName = element.displayName;
    final bindingName =
        coerceString(value, 'bindingPropertyName', defaultTo: propertyName);
    _prohibitBindingChange(element.enclosingElement as ClassElement,
        propertyName, bindingName, immutableBindings ?? bindings);
    bindings[propertyName] = bindingName;
  }

  /// Collects inheritable metadata declared on [element].
  void _collectInheritableMetadataOn(ClassElement element) {
    // Skip 'Object' since it can't have metadata and we only want to record
    // whether a user type implements 'noSuchMethod'.
    if (element.type.isObject) return;
    if (element.getMethod('noSuchMethod') != null) {
      _implementsNoSuchMethod = true;
    }
    // Collect metadata from field and property accessor annotations.
    super.visitClassElement(element);
    // Merge field and setter inputs, so that a derived field input binding is
    // not overridden by an inherited setter input.
    _inputs..addAll(_fieldInputs)..addAll(_setterInputs);
    _fieldInputs..clear();
    _setterInputs..clear();
  }

  /// Collects inheritable metadata from [element] and its supertypes.
  void _collectInheritableMetadata(ClassElement element) {
    // Reverse supertypes to traverse inheritance hierarchy from top to bottom
    // so that derived bindings overwrite their inherited definition.
    for (var type in element.allSupertypes.reversed) {
      _collectInheritableMetadataOn(type.element);
    }
    _collectInheritableMetadataOn(element);
  }

  CompileDirectiveMetadata _createCompileDirectiveMetadata(
      IndexedAnnotation<ClassElement> indexedAnnotation) {
    final element = indexedAnnotation.element;
    final annotation = indexedAnnotation.annotation;

    _directiveClassElement = element;
    DirectiveVisitor(
      onHostBinding: _addHostBinding,
      onHostListener: _addHostListener,
    ).visitDirective(element);
    _collectInheritableMetadata(element);
    final isComp = safeMatcher(isComponent)(annotation);
    final annotationValue = annotation.computeConstantValue();

    if (annotation.constantEvaluationErrors.isNotEmpty) {
      _exceptionHandler.handle(AngularAnalysisError(
          annotation.constantEvaluationErrors, indexedAnnotation));
      return null;
    }

    // Some directives won't have templates but the template parser is going to
    // assume they have at least defaults.
    CompileTypeMetadata componentType =
        element.accept(CompileTypeMetadataVisitor(_library));
    final template = isComp
        ? _createTemplateMetadata(annotationValue, componentType)
        : CompileTemplateMetadata();
    final analyzedClass =
        AnalyzedClass(element, isMockLike: _implementsNoSuchMethod);
    final lifecycleHooks = extractLifecycleHooks(element);
    if (lifecycleHooks.contains(LifecycleHooks.doCheck)) {
      final ngDoCheck = element.getMethod('ngDoCheck') ??
          element.lookUpInheritedMethod('ngDoCheck', element.library);
      if (ngDoCheck != null && ngDoCheck.isAsynchronous) {
        _exceptionHandler.handle(ErrorMessageForElement(
            ngDoCheck,
            'ngDoCheck should not be "async". The "ngDoCheck" lifecycle event '
            'must be strictly synchronous, and should not invoke any methods '
            '(or getters/setters) that directly run asynchronous code (such as '
            'microtasks, timers).'));
      }
      if (lifecycleHooks.contains(LifecycleHooks.onChanges)) {
        _exceptionHandler.handle(ErrorMessageForElement(
            element,
            'Cannot implement both the DoCheck and OnChanges lifecycle '
            'events. By implementing "DoCheck", default change detection of '
            'inputs is disabled, meaning that "ngOnChanges" will never be '
            'invoked with values. Consider "AfterChanges" instead.'));
      }
    }

    final selector = coerceString(annotationValue, 'selector');
    if (selector == null || selector.isEmpty) {
      _exceptionHandler.handle(ErrorMessageForAnnotation(
        indexedAnnotation,
        'Selector is required, got "$selector"',
      ));
    }

    return CompileDirectiveMetadata(
      type: componentType,
      originType: componentType,
      metadataType: isComp
          ? CompileDirectiveMetadataType.Component
          : CompileDirectiveMetadataType.Directive,
      selector: coerceString(annotationValue, 'selector'),
      exportAs: coerceString(annotationValue, 'exportAs'),
      // Even for directives, we want change detection set to the default.
      changeDetection:
          _changeDetection(element, annotationValue, 'changeDetection'),
      inputs: _inputs,
      inputTypes: _inputTypes,
      outputs: _outputs,
      hostBindings: _hostBindings,
      hostListeners: _hostListeners,
      analyzedClass: analyzedClass,
      lifecycleHooks: lifecycleHooks,
      providers: _extractProviders(annotationValue, 'providers'),
      viewProviders: _extractProviders(annotationValue, 'viewProviders'),
      exports: _extractExports(annotation as ElementAnnotationImpl, element),
      queries: _queries,
      viewQueries: _viewQueries,
      template: template,
      visibility: coerceEnum(
        annotationValue,
        _visibilityProperty,
        Visibility.values,
        defaultTo: Visibility.local,
      ),
    );
  }

  CompileTemplateMetadata _createTemplateMetadata(
      DartObject component, CompileTypeMetadata componentType) {
    var template = component;
    String templateContent = coerceString(template, 'template');
    String templateUrl = coerceString(template, 'templateUrl');
    if (templateContent != null && templateUrl != null) {
      // TODO: https://github.com/dart-lang/angular/issues/851.
      log.severe(''
          'Component "${componentType.name}" in\n  ${componentType.moduleUrl}:\n'
          '  Cannot supply both "template" and "templateUrl"');
    }
    return CompileTemplateMetadata(
      encapsulation: _encapsulation(template),
      template: templateContent,
      templateUrl: templateUrl,
      styles: coerceStringList(template, 'styles'),
      styleUrls: coerceStringList(template, 'styleUrls'),
      preserveWhitespace: coerceBool(
        component,
        'preserveWhitespace',
        defaultTo: false,
      ),
    );
  }

  ViewEncapsulation _encapsulation(DartObject value) => coerceEnum(
        value,
        'encapsulation',
        ViewEncapsulation.values,
        defaultTo: ViewEncapsulation.Emulated,
      );

  int _changeDetection(
    ClassElement clazz,
    DartObject value,
    String field,
  ) {
    // TODO: Use angular2/src/meta instead of this error-prone check.
    if (clazz.allSupertypes.any((t) => t.name == 'ComponentState')) {
      // TODO: Warn/fail if changeDetection: ... is set to anything else.
      return ChangeDetectionStrategy.Stateful;
    }
    return coerceInt(value, field, defaultTo: ChangeDetectionStrategy.Default);
  }

  List<CompileProviderMetadata> _extractProviders(
          DartObject component, String providerField) =>
      visitAll(
          const ModuleReader()
              .extractProviderObjects(getField(component, providerField)),
          CompileTypeMetadataVisitor(_library).createProviderMetadata);

  List<CompileIdentifierMetadata> _extractExports(
      ElementAnnotationImpl annotation, ClassElement element) {
    var exports = <CompileIdentifierMetadata>[];

    // There is an implicit "export" for the directive class itself
    exports.add(CompileIdentifierMetadata(
        name: element.name,
        moduleUrl: moduleUrl(element.library),
        analyzedClass: AnalyzedClass(element)));

    var arguments = annotation.annotationAst.arguments.arguments;
    var exportsArg = arguments.whereType<NamedExpression>().firstWhere(
        (arg) => arg.name.label.name == 'exports',
        orElse: () => null);
    if (exportsArg == null || exportsArg.expression is! ListLiteral) {
      return exports;
    }

    var staticNames = (exportsArg.expression as ListLiteral).elements;
    if (!staticNames.every((name) => name is Identifier)) {
      log.severe('Every item in the "exports" field must be an identifier');
      return exports;
    }

    final unresolvedExports = <Identifier>[];
    for (var staticName in staticNames) {
      var id = staticName as Identifier;
      String name;
      String prefix;
      AnalyzedClass analyzedClass;
      if (id is PrefixedIdentifier) {
        // We only allow prefixed identifiers to have library prefixes.
        if (id.prefix.staticElement is! PrefixElement) {
          log.severe('Every item in the "exports" field must be either '
              'a simple identifier or an identifier with a library prefix');
          return exports;
        }
        name = id.identifier.name;
        prefix = id.prefix.name;
      } else {
        name = id.name;
      }

      final staticElement = id.staticElement;
      if (staticElement is ClassElement) {
        analyzedClass = AnalyzedClass(staticElement);
      } else if (staticElement == null) {
        unresolvedExports.add(id);
        continue;
      }

      // TODO(het): Also store the `DartType` since we know it statically.
      exports.add(CompileIdentifierMetadata(
        name: name,
        prefix: prefix,
        moduleUrl: moduleUrl(staticElement.library),
        analyzedClass: analyzedClass,
      ));
    }
    if (unresolvedExports.isNotEmpty) {
      _exceptionHandler.handle(UnresolvedExpressionError(unresolvedExports,
          _directiveClassElement, annotation.compilationUnit));
    }
    return exports;
  }
}

List<LifecycleHooks> extractLifecycleHooks(ClassElement clazz) {
  const hooks = <TypeChecker, LifecycleHooks>{
    TypeChecker.fromRuntime(OnInit): LifecycleHooks.onInit,
    TypeChecker.fromRuntime(OnDestroy): LifecycleHooks.onDestroy,
    TypeChecker.fromRuntime(DoCheck): LifecycleHooks.doCheck,
    TypeChecker.fromRuntime(OnChanges): LifecycleHooks.onChanges,
    TypeChecker.fromRuntime(AfterChanges): LifecycleHooks.afterChanges,
    TypeChecker.fromRuntime(AfterContentInit): LifecycleHooks.afterContentInit,
    TypeChecker.fromRuntime(AfterContentChecked):
        LifecycleHooks.afterContentChecked,
    TypeChecker.fromRuntime(AfterViewInit): LifecycleHooks.afterViewInit,
    TypeChecker.fromRuntime(AfterViewChecked): LifecycleHooks.afterViewChecked,
  };
  return hooks.keys
      .where((hook) => hook.isAssignableFrom(clazz))
      .map((t) => hooks[t])
      .toList();
}

/// Ensures that all entries in [directiveTypes] match an entry in [directives].
void _errorOnUnusedDirectiveTypes(
    ClassElement element,
    List<CompileDirectiveMetadata> directives,
    List<CompileTypedMetadata> directiveTypes,
    FindComponentsExceptionHandler exceptionHandler) {
  if (directiveTypes.isEmpty) return;

  // Creates a unique key given a module URL and symbol name.
  String key(String moduleUrl, String name) => '$moduleUrl#$name';

  // The set of directives declared for use.
  var used = directives.map((d) => key(d.type.moduleUrl, d.type.name)).toSet();

  // Throw if the user attempts to type any directives that aren't used.
  for (var directiveType in directiveTypes) {
    var typed = key(directiveType.moduleUrl, directiveType.name);
    if (!used.contains(typed)) {
      exceptionHandler.handle(UnusedDirectiveTypeError(element, directiveType));
    }
  }
}

class IndexedAnnotation<T extends Element> {
  final T element;
  final ElementAnnotation annotation;
  final int annotationIndex;

  IndexedAnnotation(this.element, this.annotation, this.annotationIndex);
}

class FindComponentsExceptionHandler {
  final List<AsyncBuildError> _errors = [];

  void handle(AsyncBuildError error) {
    _errors.add(error);
  }

  Future<void> maybeReportErrors() async {
    if (_errors.isEmpty) {
      return;
    }
    final buildErrors =
        await Future.wait(_errors.map((error) => error.resolve()));
    throw BuildError(
        buildErrors.map((buildError) => buildError.message).join("\n\n"));
  }
}

class AsyncBuildError extends BuildError {
  Future<BuildError> resolve() => Future.value(this);
}

class AngularAnalysisError extends AsyncBuildError {
  final List<AnalysisError> constantEvaluationErrors;
  final IndexedAnnotation<ClassElement> indexedAnnotation;

  AngularAnalysisError(this.constantEvaluationErrors, this.indexedAnnotation);

  @override
  Future<BuildError> resolve() async {
    bool hasOffsetInformation =
        constantEvaluationErrors.any((error) => error.offset != 0);
    // If this code is called from a tool using [AnalysisResolvers], then
    //   1) [constantEvaluationErrors] already has source location information
    //   2) [ResolvedLibraryResultImpl] will NOT have the errors.
    // So, we return immediately with the information in
    // [constantEvaluationErrors].
    if (hasOffsetInformation) {
      return Future.value(_buildErrorForAnalysisErrors(
          constantEvaluationErrors, indexedAnnotation.element));
    }

    var libraryElement = indexedAnnotation.element.library;
    var libraryResult = await ResolvedLibraryResultImpl.tmp(libraryElement);
    var classResult =
        libraryResult.getElementDeclaration(indexedAnnotation.element);

    ClassDeclaration classDeclaration = classResult.node;
    final resolvedAnnotation =
        classDeclaration.metadata[indexedAnnotation.annotationIndex];

    // Only include the errors that are inside the annotation.
    return _buildErrorForAnalysisErrors(
        classResult.resolvedUnit.errors.where((error) =>
            error.offset >= resolvedAnnotation.offset &&
            error.offset <= resolvedAnnotation.end),
        indexedAnnotation.element);
  }

  BuildError _buildErrorForAnalysisErrors(
      Iterable<AnalysisError> errors, ClassElement componentType) {
    return BuildError(
      messages.unresolvedSource(
        errors.map((e) {
          final sourceUrl = e.source.uri;
          final sourceContent = e.source.contents.data;

          if (sourceContent.isEmpty) {
            return SourceSpanMessageTuple(
                SourceSpan(
                    SourceLocation(0, sourceUrl: sourceUrl, line: 0, column: 0),
                    SourceLocation(0, sourceUrl: sourceUrl, line: 0, column: 0),
                    ''),
                '${e.message} [with offsets into source file missing]');
          }

          return SourceSpanMessageTuple(
            sourceSpanWithLineInfo(
              e.offset,
              e.length,
              sourceContent,
              sourceUrl,
            ),
            e.message,
          );
        }),
        reason: ''
            'Compiling @Component-annotated class "${componentType.name}" '
            'failed.\n\n${messages.analysisFailureReasons}',
      ),
    );
  }
}

class UnresolvedExpressionError extends AsyncBuildError {
  final Iterable<AstNode> expressions;
  final ClassElement componentType;
  final CompilationUnitElement compilationUnit;

  UnresolvedExpressionError(
      this.expressions, this.componentType, this.compilationUnit);

  @override
  Future<BuildError> resolve() =>
      Future.value(_buildErrorForUnresolvedExpressions(
          expressions, componentType, compilationUnit));

  // TODO(deboer): Since we are checking ElementAnnotation.constantValueErrors,
  // all code paths that call this function are unreachable.
  // If we don't see any errors in the wild, delete this code.
  BuildError _buildErrorForUnresolvedExpressions(Iterable<AstNode> expressions,
      ClassElement componentType, CompilationUnitElement compilationUnit) {
    return BuildError(
      messages.unresolvedSource(
        expressions.map((e) {
          return SourceSpanMessageTuple(
            sourceSpanWithLineInfo(
              e.offset,
              e.length,
              componentType.source.contents.data,
              componentType.source.uri,
              lineInfo: compilationUnit.lineInfo,
            ),
            'This argument *may* have not been resolved',
          );
        }),
        reason: ''
            'Compiling @Component annotated class "${componentType.name}" '
            'failed.\n'
            'NOTE: Your build triggered an error in the Angular error reporting\n'
            'code. Please report a bug: ${messages.urlFileBugs}\n'
            '\n\n${messages.analysisFailureReasons}',
      ),
    );
  }
}

class UnusedDirectiveTypeError extends ErrorMessageForAnnotation {
  final ClassElement element;
  final CompileTypedMetadata directiveType;

  static IndexedAnnotation firstComponentAnnotation(ClassElement element) {
    final index = element.metadata.indexWhere(isComponent);
    if (index == -1)
      throw ArgumentError("[element] must have a @Component annotation");
    return IndexedAnnotation(element, element.metadata[index], index);
  }

  UnusedDirectiveTypeError(this.element, this.directiveType)
      : super(
            firstComponentAnnotation(element),
            'Entry in "directiveTypes" missing corresponding entry in '
            '"directives" for "${directiveType.name}".\n\n'
            'If you recently removed "${directiveType.name}" from "directives", '
            'please also remove its corresponding entry from "directiveTypes".');
}

class ErrorMessageForAnnotation extends AsyncBuildError {
  final IndexedAnnotation indexedAnnotation;
  final String message;

  ErrorMessageForAnnotation(this.indexedAnnotation, this.message);

  @override
  Future<BuildError> resolve() async {
    final element = indexedAnnotation.element;
    final annotationIndex = indexedAnnotation.annotationIndex;

    var libraryResult = await ResolvedLibraryResultImpl.tmp(element.library);
    var result = libraryResult.getElementDeclaration(element);
    AnnotatedNode annotatedNode = result.node;
    if (annotatedNode.metadata.length != element.metadata.length) {
      // [ResolvedLibraryResultImpl] lost the metadata, so return the
      // original annotation even though it probably doesn't have the correct
      // information.
      return BuildError.forAnnotation(
          element.metadata[annotationIndex], message);
    }
    ElementAnnotation resolvedAnnotation =
        annotatedNode.metadata[annotationIndex].elementAnnotation;
    return BuildError.forAnnotation(resolvedAnnotation, message);
  }
}

class ErrorMessageForElement extends AsyncBuildError {
  final Element element;
  final String message;

  ErrorMessageForElement(this.element, this.message);

  @override
  Future<BuildError> resolve() =>
      Future.value(BuildError.forElement(element, message));
}

void _prohibitBindingChange(
  ClassElement element,
  String propertyName,
  String bindingName,
  Map<String, String> bindings,
) {
  if (bindings.containsKey(propertyName) &&
      bindings[propertyName] != bindingName) {
    log.severe(
        "'${element.displayName}' overwrites the binding name of property "
        "'$propertyName' from '${bindings[propertyName]}' to '$bindingName'.");
  }
}

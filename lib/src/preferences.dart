import 'dart:async';
import 'dart:convert';

import 'package:build/build.dart';
import 'package:code_builder/code_builder.dart';
import 'package:dart_style/dart_style.dart';
import 'package:recase/recase.dart';

class PreferencesBuilder extends Builder {
  static const String defaultClassName = "GeneratedPreferences";

  @override
  FutureOr<void> build(BuildStep buildStep) async {
    final AssetId outputAsset = AssetId(
      buildStep.inputId.package,
      'lib/generated/preferences.dart',
    );

    final DartEmitter emitter = DartEmitter(useNullSafetySyntax: true);
    final DartFormatter formatter = DartFormatter();
    final Map<String, dynamic> json;

    try {
      final dynamic parsedJson = jsonDecode(
        await buildStep.readAsString(buildStep.inputId),
      );
      json = parsedJson as Map<String, dynamic>;
    } catch (e) {
      log.severe("The referenced file is not valid json");
      return;
    }

    final List<String>? additionalImports =
        json.getOptionalList<String>("additionalImports");
    final LibraryBuilder generatedLibrary = LibraryBuilder();
    generatedLibrary.directives.add(
      Directive(
        (b) => b
          ..url = "package:liblymph/providers.dart"
          ..type = DirectiveType.import,
      ),
    );
    if (additionalImports != null) {
      generatedLibrary.directives.addAll(
        additionalImports.map(
          (e) => Directive(
            (b) => b
              ..url = e
              ..type = DirectiveType.import,
          ),
        ),
      );
    }

    final String? requestedClassName = json.getOptional<String>("className");
    final ClassBuilder generatedClass = ClassBuilder();
    generatedClass.name = requestedClassName ?? defaultClassName;
    generatedClass.extend = refer('LocalPreferences');
    generatedClass.constructors.add(
      Constructor(
        (b) => b
          ..constant = true
          ..optionalParameters.add(
            Parameter(
              (b) => b
                ..required = true
                ..name = 'backend'
                ..type = refer('LocalPreferencesBackend')
                ..named = true,
            ),
          )
          ..initializers.add(const Code('super(backend: backend)')),
      ),
    );

    final List<Map<String, dynamic>> preferences =
        json.getRequiredList<Map<String, dynamic>>("preferences");

    for (final Map<String, dynamic> pref in preferences) {
      final _JsonLocalPreference preference =
          _JsonLocalPreference.fromJson(pref);

      final Reference getterType;
      final Reference setterType;
      final String getterCode;
      final String setterCode;

      final String isNullable = preference.defaultValue == null ? "?" : "";

      if (preference.type == _JsonLocalPreferenceType.enumerated) {
        final String enumName =
            preference.enumNameOverride ?? preference.name.pascalCase;
        final bool refersToExistingEnum = preference.refersToExistingEnum;

        if (!refersToExistingEnum) {
          final EnumBuilder generatedEnum = EnumBuilder();
          generatedEnum.name = enumName;
          generatedEnum.values.addAll(
            preference.enumValues!.values.map(
              (e) => EnumValue((v) => v..name = e),
            ),
          );

          generatedLibrary.body.add(generatedEnum.build());
        }

        getterType = refer(enumName + isNullable);
        setterType = refer('$enumName?');
        getterCode = _buildEnumGetter(enumName, preference);
        setterCode = _buildEnumSetter(enumName, preference);
      } else {
        getterType = refer(preference.type.nativeType + isNullable);
        setterType = refer('${preference.type.nativeType}?');
        getterCode = _buildSimpleGetter(preference);
        setterCode = _buildSimpleSetter(preference);
      }

      final MethodBuilder getter = MethodBuilder();
      getter.type = MethodType.getter;
      getter.name = preference.name.camelCase;
      getter.returns = getterType;
      getter.body = Code(getterCode);

      final MethodBuilder setter = MethodBuilder();
      setter.type = MethodType.setter;
      setter.name = preference.name.camelCase;
      setter.requiredParameters.add(
        Parameter(
          (p) => p
            ..type = setterType
            ..name = 'value',
        ),
      );
      setter.body = Code(setterCode);

      generatedClass.methods.add(getter.build());
      generatedClass.methods.add(setter.build());
    }

    generatedLibrary.body.add(generatedClass.build());

    buildStep.writeAsString(
      outputAsset,
      formatter.format(generatedLibrary.build().accept(emitter).toString()),
    );
  }

  @override
  final Map<String, List<String>> buildExtensions = const {
    "^assets/data/preferences.json": ["lib/generated/preferences.dart"],
  };
}

String _buildSimpleGetter(_JsonLocalPreference preference) {
  final StringBuffer buffer = StringBuffer('return ');
  buffer.write(
    'backend.${preference.type.backendGetMethod}("${preference.name}")',
  );

  if (preference.defaultValue != null) {
    buffer.write(" ?? ${preference.defaultValue}");
  }

  buffer.write(";");

  return buffer.toString();
}

String _buildSimpleSetter(_JsonLocalPreference preference) {
  return 'backend.${preference.type.backendSetMethod}("${preference.name}", value);';
}

String _buildEnumGetter(String enumName, _JsonLocalPreference preference) {
  final StringBuffer buffer = StringBuffer();
  buffer.writeln(
    'int? value = backend.${preference.type.backendGetMethod}("${preference.name}");',
  );

  buffer.writeln('switch(value) {');
  preference.enumValues!.forEach((key, value) {
    buffer.writeln('case $key:');
    buffer.writeln('return $enumName.$value;');
  });
  buffer.writeln('}');
  buffer.writeln();

  if (preference.defaultValue != null) {
    buffer.writeln('return $enumName.${preference.defaultValue};');
  } else {
    buffer.writeln('return null;');
  }

  return buffer.toString();
}

String _buildEnumSetter(String enumName, _JsonLocalPreference preference) {
  final StringBuffer buffer = StringBuffer();
  buffer.writeln('if(value == null) {');
  buffer.writeln(
    'backend.${preference.type.backendSetMethod}("${preference.name}", null);',
  );
  buffer.writeln("return;");
  buffer.writeln("}");
  buffer.writeln();
  buffer.writeln('final int resolvedValue;');

  buffer.writeln();
  buffer.writeln('switch(value) {');
  preference.enumValues!.forEach((key, value) {
    buffer.writeln('case $enumName.$value:');
    buffer.writeln('resolvedValue = $key;');
    buffer.writeln('break;');
  });
  buffer.writeln('}');
  buffer.writeln();

  buffer.writeln(
    'backend.${preference.type.backendSetMethod}("${preference.name}", resolvedValue);',
  );

  return buffer.toString();
}

class _JsonLocalPreference<T> {
  final String name;
  final T? defaultValue;
  final _JsonLocalPreferenceType type;
  final Map<String, String>? enumValues;
  final String? enumNameOverride;
  final bool refersToExistingEnum;

  const _JsonLocalPreference({
    required this.name,
    required this.defaultValue,
    required this.type,
    this.enumValues,
    this.enumNameOverride,
    this.refersToExistingEnum = false,
  });

  static _JsonLocalPreference fromJson(Map<String, dynamic> json) {
    final String name = json.getRequired<String>('name');
    final String stringType = json.getRequired<String>('type');
    final _JsonLocalPreferenceType type;

    switch (stringType) {
      case 'int':
        type = _JsonLocalPreferenceType.int;
        final int? defaultValue = json.getOptional<int>('defaultValue');
        return _JsonLocalPreference<int>(
          name: name,
          defaultValue: defaultValue,
          type: type,
        );
      case 'double':
        type = _JsonLocalPreferenceType.double;
        final double? defaultValue = json.getOptional<double>('defaultValue');
        return _JsonLocalPreference<double>(
          name: name,
          defaultValue: defaultValue,
          type: type,
        );
      case 'bool':
        type = _JsonLocalPreferenceType.bool;
        final bool? defaultValue = json.getOptional<bool>('defaultValue');
        return _JsonLocalPreference<bool>(
          name: name,
          defaultValue: defaultValue,
          type: type,
        );
      case 'string':
        type = _JsonLocalPreferenceType.string;
        final String? defaultValue = json.getOptional<String>('defaultValue');
        return _JsonLocalPreference<String>(
          name: name,
          defaultValue: defaultValue != null ? jsonEncode(defaultValue) : null,
          type: type,
        );
      case 'stringList':
        type = _JsonLocalPreferenceType.stringList;
        final List<String>? defaultValue =
            json.getOptionalList<String>('defaultValue');
        return _JsonLocalPreference<List<String>>(
          name: name,
          defaultValue: defaultValue,
          type: type,
        );
      case 'enumerated':
        type = _JsonLocalPreferenceType.enumerated;
        final Map<String, String> values =
            json.getRequiredMap<String, String>('values');
        final String? defaultValue = json.getOptional<String>('defaultValue');
        final String? nameOverride = json.getOptional<String>('nameOverride');
        final bool? refersToExistingEnum =
            json.getOptional<bool>('refersToExistingEnum');

        return _JsonLocalPreference<String>(
          name: name,
          defaultValue: defaultValue,
          type: type,
          enumValues: values,
          enumNameOverride: nameOverride,
          refersToExistingEnum: refersToExistingEnum ?? false,
        );
      default:
        throw BadValueException(
          'type',
          stringType,
          _JsonLocalPreferenceType.values.map((e) => e.name).toList(),
        );
    }
  }
}

Never _typeMismatchHandler<T>(dynamic value) {
  throw BadTypeException<T>('defaultValue', value);
}

enum _JsonLocalPreferenceType {
  int('int', 'getInt', 'setInt'),
  double('double', 'getDouble', 'setDouble'),
  bool('bool', 'getBool', 'setBool'),
  string('String', 'getString', 'setString'),
  stringList('List<String>', 'getStringList', 'setStringList'),
  enumerated('Enum', 'getInt', 'setInt');

  final String nativeType;
  final String backendGetMethod;
  final String backendSetMethod;

  const _JsonLocalPreferenceType(
    this.nativeType,
    this.backendGetMethod,
    this.backendSetMethod,
  );
}

class MissingRequiredEntryException implements Exception {
  final String entryName;

  const MissingRequiredEntryException(this.entryName);

  @override
  String toString() {
    return 'The source data is missing the required parameter $entryName.';
  }
}

class BadValueException<T> implements Exception {
  final String parameterName;
  final T receivedValue;
  final List<T> validValues;

  const BadValueException(
    this.parameterName,
    this.receivedValue,
    this.validValues,
  );

  @override
  String toString() {
    return 'The value "$receivedValue" for $parameterName is not contained in the range of accepted values: ${validValues.join(", ")}.';
  }
}

class BadTypeException<T> implements Exception {
  final String parameterName;
  final dynamic receivedValue;

  const BadTypeException(
    this.parameterName,
    this.receivedValue,
  );

  @override
  String toString() {
    return 'The value "$receivedValue" for $parameterName is not of the expected type $T.';
  }
}

typedef _OnTypeMismatch = Never Function(dynamic value);

extension on Map<String, dynamic> {
  static const _OnTypeMismatch _defaultTypeMismatch = _typeMismatchHandler;

  T getRequired<T>(
    String key, {
    _OnTypeMismatch? onTypeMismatch,
  }) {
    onTypeMismatch ??= _defaultTypeMismatch;

    final dynamic value = this[key];

    if (value != null) {
      if (value is! T) onTypeMismatch(value);

      return value;
    }

    throw MissingRequiredEntryException(key);
  }

  Map<K, V> getRequiredMap<K, V>(
    String key, {
    _OnTypeMismatch? onTypeMismatch,
  }) {
    return getRequired<Map<String, dynamic>>(
      key,
      onTypeMismatch: onTypeMismatch,
    ).cast<K, V>();
  }

  List<T> getRequiredList<T>(
    String key, {
    _OnTypeMismatch? onTypeMismatch,
  }) {
    return getRequired<List<dynamic>>(
      key,
      onTypeMismatch: onTypeMismatch,
    ).cast<T>();
  }

  T? getOptional<T>(String key, {_OnTypeMismatch? onTypeMismatch}) {
    onTypeMismatch ??= _defaultTypeMismatch;

    final dynamic value = this[key];

    if (value == null) return null;
    if (value is! T) onTypeMismatch(value);

    return value;
  }

  List<T>? getOptionalList<T>(
    String key, {
    _OnTypeMismatch? onTypeMismatch,
  }) {
    return getOptional<List<dynamic>>(
      key,
      onTypeMismatch: onTypeMismatch,
    )?.cast<T>();
  }
}

class BuildLocalPreferences {
  final String preferenceJsonPath;

  const BuildLocalPreferences(this.preferenceJsonPath);
}

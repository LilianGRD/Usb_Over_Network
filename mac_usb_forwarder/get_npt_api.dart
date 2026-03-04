import 'dart:mirrors';
import 'package:noports_core/npt.dart';

void main() {
  ClassMirror classMirror = reflectClass(Npt);
  
  for (var c in classMirror.declarations.values) {
    if (c is MethodMirror && c.isConstructor) {
      print('Constructor: ${c.simpleName}');
      for (var param in c.parameters) {
        print('  Param: ${MirrorSystem.getName(param.simpleName)} (type: ${param.type.simpleName}) isNamed: ${param.isNamed} isOptional: ${param.isOptional}');
      }
    }
  }
}

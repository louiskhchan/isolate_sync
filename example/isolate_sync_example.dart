import 'package:isolate_sync/isolate_sync.dart';

void funcInIsolate({
  required List args,
}) {
  if (args
      case [
        int i1,
        String s1,
        SyncValue<String> s,
        SyncValue<ASerializableClass> s2,
      ]) {
    print('in isolate:');
    print(i1);
    print(s1);
    print(s.value);
    print(s2.value);
    s.value = 'after sync';
    s2.value.i = 22;
    s2.value.s = 'orange';
    s2.sync(); // needed because we are syncing the fields of the value, the value hasn't changed
    print(s.value);
    print(s2.value);
  }
}

class ASerializableClass {
  int i;
  String s;
  ASerializableClass({
    required this.i,
    required this.s,
  });
  @override
  String toString() => 'ASerializableClass $i $s';
}

void main() async {
  var isync = IsolateSync();
  final s2 = SyncValue(ASerializableClass(i: 11, s: 'apple'));
  print(s2.value);
  final s = SyncValue('before sync');
  await isync.run(
    funcInIsolate,
    args: [
      1,
      'hello',
      s,
      s2,
    ],
  );
  print('back to main');
  print(s.value);
  print(s2.value);
  isync.close();
  print('bye.');
}

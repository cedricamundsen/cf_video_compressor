// On-device smoke test (no video needed): the native side is registered,
// owns its temp dir, and refuses to delete files outside it.
//   flutter test integration_test   (with a device connected)

import 'package:cf_video_compressor/cf_video_compressor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('temp dir is plugin-owned and cleanable', (tester) async {
    final c = CfVideoCompressor();
    final dir = await c.tempDirectory();
    expect(dir, endsWith('/cf_compress'));
    expect(await c.deleteAllOutputs(), greaterThanOrEqualTo(0));
  });

  testWidgets('refuses to delete outside the temp dir', (tester) async {
    final c = CfVideoCompressor();
    await expectLater(
      c.deleteOutput('/sdcard/DCIM/Camera/original.mp4'),
      throwsA(isA<CompressionException>()),
    );
  });

  testWidgets('cancel with nothing running is a no-op', (tester) async {
    expect(await CfVideoCompressor().cancel(), isFalse);
  });
}

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hasura_offline_first/hasura_offline_first.dart';
import 'mocks/fake_connectivity.dart';

void main() {
  group('NetworkManager', () {
    late FakeConnectivity fakeConnectivity;
    late NetworkManager networkManager;

    setUp(() {
      fakeConnectivity = FakeConnectivity();
      networkManager = NetworkManager(connectivity: fakeConnectivity);
    });

    tearDown(() {
      networkManager.dispose();
      fakeConnectivity.dispose();
    });

    test('initial status is online when connectivity returns wifi', () async {
      final isConnected = await networkManager.isConnected;
      expect(isConnected, isTrue);
    });

    test('emits offline when connectivity changes to none', () async {
      final statuses = <NetworkStatus>[];
      final sub = networkManager.onStatusChanged.listen(statuses.add);

      fakeConnectivity.emit([ConnectivityResult.none]);
      await pumpEventQueue();

      expect(statuses, contains(NetworkStatus.offline));
      await sub.cancel();
    });

    test('addListener triggers immediately and returns cancel callback',
        () async {
      final recorded = <NetworkStatus>[];
      final cancel = networkManager.addListener((status) {
        recorded.add(status);
      });

      fakeConnectivity.emit([ConnectivityResult.none]);
      await pumpEventQueue();

      expect(recorded, contains(NetworkStatus.offline));

      cancel();
      fakeConnectivity.emit([ConnectivityResult.mobile]);
      await pumpEventQueue();

      expect(recorded.last, equals(NetworkStatus.offline));
    });
  });
}

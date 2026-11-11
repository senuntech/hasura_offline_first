/// Enum representing the network status.
enum NetworkStatus {
  online,
  offline,
}

/// Callback function triggered when network status changes.
typedef ConnectivityListener = void Function(NetworkStatus status);

/// Callback function to unsubscribe/dispose a registered listener.
typedef VoidCallback = void Function();

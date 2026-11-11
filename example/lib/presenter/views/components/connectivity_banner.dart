import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../controllers/connectivity_controller.dart';

class ConnectivityBanner extends StatelessWidget {
  const ConnectivityBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final connectivity = context.watch<ConnectivityController>();
    final isOnline = connectivity.isOnline;
    final isSimulated = connectivity.isSimulatingOffline;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      color: isOnline ? Colors.teal.shade700 : Colors.deepOrange.shade800,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          Row(
            children: [
              Icon(
                isOnline ? Icons.cloud_done : Icons.cloud_off,
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isOnline
                      ? 'Conectado • Hasura sincronizado'
                      : (isSimulated
                          ? 'Modo Offline (Simulado) • Outbox ativo'
                          : 'Modo Offline (Sem Rede) • Outbox ativo'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  isOnline
                      ? 'ONLINE'
                      : (isSimulated ? 'OFFLINE (SIM)' : 'OFFLINE'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      isSimulated ? Icons.wifi_off : Icons.wifi,
                      size: 16,
                      color: Colors.white70,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Simular falta de internet:',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                Transform.scale(
                  scale: 0.8,
                  child: Switch.adaptive(
                    value: isSimulated,
                    activeTrackColor: Colors.amberAccent,
                    onChanged: (value) {
                      connectivity.setSimulateOffline(value);
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

package com.solverpro.j16_tracker

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Canal usado pela notificação fixa do serviço do rastreador.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                "j16_tracker",
                "Rastreador J16",
                NotificationManager.IMPORTANCE_LOW,
            )
            channel.description = "Status do rastreador em segundo plano"
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
        super.onCreate(savedInstanceState)
    }
}

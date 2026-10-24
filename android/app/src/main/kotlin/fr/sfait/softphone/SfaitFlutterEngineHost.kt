package fr.sfait.softphone

import android.content.Context
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant

object SfaitFlutterEngineHost {
    private const val ENGINE_ID = "sfait_softphone_engine"

    @Synchronized
    fun ensureEngine(context: Context): FlutterEngine {
        val appContext = context.applicationContext
        val cache = FlutterEngineCache.getInstance()
        val cachedEngine = cache.get(ENGINE_ID)
        if (cachedEngine != null) {
            configureChannels(appContext, cachedEngine)
            return cachedEngine
        }

        FlutterInjector.instance().flutterLoader().startInitialization(appContext)
        FlutterInjector.instance().flutterLoader().ensureInitializationComplete(appContext, null)

        val engine = FlutterEngine(appContext)
        GeneratedPluginRegistrant.registerWith(engine)
        configureChannels(appContext, engine)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault(),
        )
        cache.put(ENGINE_ID, engine)
        return engine
    }

    fun configureChannels(context: Context, flutterEngine: FlutterEngine) {
        SfaitAndroidCallBridge.configure(context.applicationContext, flutterEngine)
        SfaitNativeChannels.configure(context.applicationContext, flutterEngine)
    }
}

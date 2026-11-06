# BeezyncSDK (Swift)

SDK de cliente de Beezync para iOS 15+ y macOS 12+. Solo usa Foundation y `URLSession` (`URLSessionWebSocketTask`); no tiene dependencias de terceros.

Qué incluye:

- Registro de dispositivos (`registerDevice`, `unregisterDevice`, `setUser`, `setTags`).
- WebSocket nativo con reconexión automática (espera exponencial de 1 s a 30 s con variación), resuscripción a los canales activos y reconexión inmediata con el código de cierre `4200`.
- Mensajes publicados y notificaciones por WebSocket como `AsyncStream`.
- Recibos y clics (`trackReceived`, `trackClicked`, `trackDismissed`).
- Utilidad para extraer `bz_id` del `userInfo` de una notificación APNs/FCM.

## Instalación

Swift Package Manager. En Xcode: File > Add Package Dependencies y elige la carpeta local o la URL del repositorio. En `Package.swift`:

```swift
dependencies: [
    .package(path: "../Add-ons/SDKs/swift")   // o .package(url: "<url del repositorio>", from: "0.1.0")
],
targets: [
    .target(name: "MiApp", dependencies: [.product(name: "BeezyncSDK", package: "swift")])
]
```

El nombre del paquete es el de la carpeta que lo contiene; el producto se llama `BeezyncSDK`.

## Uso

```swift
import BeezyncSDK

let config = BeezyncConfiguration(
    appId: "UUID-de-la-app",
    publicKey: "pk_...",                 // nunca la llave secreta
    baseUrl: URL(string: "https://api.beezync.com")!
)
let beezync = BeezyncClient(configuration: config)

// Dispositivo (el token es el de FCM)
try await beezync.registerDevice(token: fcmToken, externalUserId: "user-42", platform: "ios", tags: ["plan": "pro"])
try await beezync.setUser("user-42")
try await beezync.setTags(["lang": "es"])
try await beezync.unregisterDevice()

// WebSocket
let messages = await beezync.messages()          // AsyncStream<BeezyncMessage>
let events = await beezync.events()              // conexión, suscripciones, desconexiones
await beezync.subscribe("noticias")              // canal público
await beezync.subscribe("private-pedidos", auth: authHex)        // o token: "..."
await beezync.connect()

for await m in messages {
    switch m.kind {
    case .published:    print(m.event ?? "", m.channel ?? "", m.data as Any)
    case .notification: print(m.title ?? "", m.body ?? "")
    }
}

await beezync.unsubscribe("noticias")
await beezync.disconnect()

// Recibos y clics
try await beezync.trackReceived(id)
try await beezync.trackClicked(id)
try await beezync.trackDismissed(id)
```

Notas:

- `subscribe` puede llamarse antes de `connect()`; los canales se guardan y se vuelven a suscribir en cada reconexión.
- Los canales `private-*` requieren `auth` (HMAC que entrega el servidor de tu aplicación vía `POST /v1/api/channels/auth`) o `token` (de `POST /v1/api/subscription-tokens`). La llave secreta nunca debe estar en la app.
- `setUser`, `setTags` y los eventos usan el token guardado por `registerDevice`; si no hay uno se lanza `BeezyncError.notRegistered` (en eventos, el token es opcional).
- Las operaciones HTTP son `async throws` y lanzan `BeezyncError` (`.http(status:code:message:)`, `.network`, `.notRegistered`). Úsalas dentro de `Task { }` y decide si reintentar.
- `onMessage { ... }` es un atajo que consume `messages()` y devuelve el `Task` para cancelarlo.
- El SDK no escribe tokens en logs.

## Extraer `bz_id` de una notificación

```swift
func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
    if let id = BeezyncPush.notificationId(from: n.request.content.userInfo) {
        Task { try? await beezync.trackReceived(id) }
    }
    return [.banner, .sound]
}

func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
    guard let id = BeezyncPush.notificationId(from: r.notification.request.content.userInfo) else { return }
    if r.actionIdentifier == UNNotificationDismissActionIdentifier {
        try? await beezync.trackDismissed(id)     // requiere categoría con .customDismissAction
    } else {
        try? await beezync.trackClicked(id)
    }
}
```

Para contar el recibo con la app cerrada o en segundo plano se necesita una Notification Service Extension y `content-available`; sin ella, el recibo se envía cuando la app se abre o el push llega en primer plano.

## Configurar push en iOS

1. En Xcode, target de la app > Signing & Capabilities: añade **Push Notifications** y **Background Modes > Remote notifications**.
2. En Apple Developer crea una llave APNs (.p8) y súbela en Firebase Console > Configuración del proyecto > Cloud Messaging > Apple app configuration (con Key ID y Team ID).
3. Añade a la app `GoogleService-Info.plist` (descargado de Firebase) y el paquete `firebase-ios-sdk` (producto `FirebaseMessaging`).
4. Llama a `FirebaseApp.configure()`, asigna `Messaging.messaging().delegate` y registra la app para notificaciones remotas. FirebaseMessaging entrega el token FCM.
5. Pasa ese token a `registerDevice(token:platform: "ios")`. En iOS, FCM entrega por APNs.
6. Cada push incluye `bz_id` en los datos; usa `BeezyncPush.notificationId(from:)` para leerlo.

Hay una app completa en `Add-ons/demos/ios-swift`.

## Pruebas

```
swift build
swift test
```

Las pruebas unitarias cubren codificación y decodificación de tramas, backoff, HTTP (con `URLProtocol` simulado) y reconexión/resuscripción con un socket falso.

Prueba opcional contra un motor real (no se ejecuta sin la variable `BEEZYNC_LIVE`). La llave secreta solo se lee del entorno:

```
export BEEZYNC_LIVE=1 BASE_URL=http://127.0.0.1:8099 APP_ID=... PUBLIC_KEY=pk_... SECRET_KEY=sk_...
swift test --filter LiveEngineTests
```

Registra un dispositivo, se suscribe a un canal público, publica con la llave secreta, envía un push con `transport: "ws"`, reporta `received` y `clicked` y comprueba los contadores en `GET /v1/api/notifications/{id}`.

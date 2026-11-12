import Logging
import SpaceCore

func notificationDeliveryClient(space: Space, logger: Logger, webPush: WebPushClient, pushRelay: PushRelayClient) -> NotificationDeliveryClient {
  NotificationDeliveryClient(
    space: space, logger: logger,
    webPush: { try await webPush.send(try await render($0, space: space)) },
    webPushDisposition: webPushDisposition,
    pushRelay: { try await pushRelay.send(try await render($0, space: space)) },
    pushRelayDisposition: pushRelayDisposition,
  )
}

func registerNotificationDelivery(space: Space, logger: Logger, webPush: WebPushClient, pushRelay: PushRelayClient) throws {
  let worker = space.worker
  worker.provide(notificationDeliveryClient(space: space, logger: logger, webPush: webPush, pushRelay: pushRelay))
  worker.register(.job(NotificationDeliveryJob.self))
  try worker.create(NotificationDeliveryJob.webPush, params: .webPush)
  try worker.create(NotificationDeliveryJob.pushRelay, params: .pushRelay)
}

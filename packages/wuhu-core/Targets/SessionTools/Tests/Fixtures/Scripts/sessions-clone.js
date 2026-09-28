import { createSession } from "wuhu:session"

try {
  const made = await createSession({
    title: "coder", template: "coder", expectsReply: true, message: "go", key: "coder",
  })
  result({ made: true, requestId: typeof made.requestId })
} catch (error) {
  result({ made: false, id: typeof error.id, message: error.message.replaceAll(error.id, "<coder>") })
}

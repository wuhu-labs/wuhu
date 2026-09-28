import { conversation } from "wuhu:space"

const me = import.meta.session
const [message] = (await conversation(me)).messages
const after = await conversation(me, { after: message.createdAt })
result(`${message.createdAt}, after it: ${after.messages.map((later) => later.id).join(" ") || "nothing"}`)

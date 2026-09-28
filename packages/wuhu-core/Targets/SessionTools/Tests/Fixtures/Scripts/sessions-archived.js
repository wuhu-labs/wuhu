import { createSession, setTags } from "wuhu:session"

const settle = (promise) => promise.then(
  (value) => value ?? "done",
  (error) => `${error.name}: ${error.message}`.replaceAll(import.meta.session, "<me>"),
)
result([
  await settle(createSession({ title: "late" })),
  await settle(setTags(import.meta.session, ["late"])),
])

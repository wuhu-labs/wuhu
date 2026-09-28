const api = await fetch("https://space.test:5530/v1/tools/ls", { method: "POST", body: "{}", credentials: "include" })
const web = await fetch("https://space.test:5531/_/query?sql=SELECT%201", { credentials: "include" })
result([api.status, web.status])

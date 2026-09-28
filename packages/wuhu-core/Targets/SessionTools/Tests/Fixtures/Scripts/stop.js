result("watching")
try {
  await sleep(3_600_000)
} catch (error) {
  update(`${error.name}: ${error.message}`)
}

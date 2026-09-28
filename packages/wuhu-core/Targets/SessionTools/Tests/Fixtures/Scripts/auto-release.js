AbortSignal.timeout(3_600_000)
result("answered")
setTimeout(() => update("the timer fired; nothing else is pending"), 1000)

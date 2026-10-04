export class OlderIntent {
  private armed = true
  private lastWheel = -Infinity

  moved(scrollTop: number) {
    if (scrollTop > 160) this.armed = true
  }

  begin() {
    this.armed = true
  }

  wheel(now: number) {
    if (now - this.lastWheel > 250) this.armed = true
    this.lastWheel = now
  }

  approach(scrollTop: number, ready: boolean): boolean {
    if (!this.armed || scrollTop > 160 || !ready) return false
    this.armed = false
    return true
  }
}

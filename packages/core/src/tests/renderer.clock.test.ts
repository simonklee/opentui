import { describe, expect, test } from "bun:test"

import type { Clock, TimerHandle } from "../lib/clock.js"
import { createTestRenderer } from "../testing/test-renderer.js"

class AdjustableClock implements Clock {
  public nowValue = 0
  public readonly timeoutDelays: number[] = []
  private nextId = 1

  public now(): number {
    return this.nowValue
  }

  public setTimeout(_: () => void, delayMs: number): TimerHandle {
    this.timeoutDelays.push(delayMs)
    return this.nextId++
  }

  public clearTimeout(handle: TimerHandle): void {
    void handle
  }

  public setInterval(_: () => void, delayMs: number): TimerHandle {
    this.timeoutDelays.push(delayMs)
    return this.nextId++
  }

  public clearInterval(handle: TimerHandle): void {
    void handle
  }
}

describe("renderer clock", () => {
  test("requestRender clamps backward clock drift when scheduling", async () => {
    const clock = new AdjustableClock()
    const { renderer } = await createTestRenderer({ clock })

    // @ts-expect-error - testing private renderer state
    renderer.lastTime = 100
    clock.nowValue = 90

    const baselineTimeoutCount = clock.timeoutDelays.length

    renderer.requestRender()

    expect(clock.timeoutDelays).toHaveLength(baselineTimeoutCount + 1)
    expect(clock.timeoutDelays.at(-1)).toBeCloseTo(1000 / 60, 5)

    renderer.destroy()
  })

  test("loop clamps negative deltaTime to zero when the clock moves backward", async () => {
    const clock = new AdjustableClock()
    const { renderer } = await createTestRenderer({ clock })

    let observedDeltaTime = Number.NaN
    renderer.setFrameCallback(async (deltaTime) => {
      observedDeltaTime = deltaTime
    })

    // @ts-expect-error - testing private renderer state
    renderer.lastTime = 100
    clock.nowValue = 90

    // @ts-expect-error - testing private renderer method
    await renderer.loop()

    expect(observedDeltaTime).toBe(0)

    renderer.destroy()
  })
})

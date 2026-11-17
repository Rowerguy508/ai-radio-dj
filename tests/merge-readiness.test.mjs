import { describe, it } from 'vitest'
import { selfTest } from '../scripts/merge-readiness.mjs'

describe('merge-readiness', () => {
  it('parses signs, the device line, and required checks the way existing PRs write them', () => {
    selfTest()
  })
})

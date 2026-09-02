import { describe, it, expect } from 'vitest';
import { sum } from './sum.js';

describe('sum', () => {
  it('adds two numbers', () => {
    expect(sum(1, 2)).toBe(3);
  });

  it('handles zeros', () => {
    expect(sum(0, 0)).toBe(0);
    expect(sum(-1, 1)).toBe(0);
  });

  it('handles negatives', () => {
    expect(sum(-5, -3)).toBe(-8);
  });
});

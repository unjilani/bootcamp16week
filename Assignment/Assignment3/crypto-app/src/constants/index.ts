const ALLOWED_SYMBOLS = ['ETH-USD', 'DOGE-USD', 'SOL-USD', 'USDT-USD'] as const

type ALLOWED_SYMBOLS_TYPE = typeof ALLOWED_SYMBOLS[number]

const STORAGE_KEY_SYMBOLS = 'selected-symbols'

export { ALLOWED_SYMBOLS, STORAGE_KEY_SYMBOLS }
export type { ALLOWED_SYMBOLS_TYPE }

-- crypto.lua - SHA-256 und HMAC-SHA256 in reinem Lua (CC hat keine eingebaute Kryptografie)
-- Geprueft gegen die Testvektoren aus FIPS 180-2 und RFC 4231 (tests/crypto_tests.lua).

local band, bor, bxor, bnot = bit32.band, bit32.bor, bit32.bxor, bit32.bnot
local rrotate, rshift = bit32.rrotate, bit32.rshift

local M = {}

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function add(...)
  local s = 0
  for i = 1, select("#", ...) do s = s + select(i, ...) end
  return s % 4294967296
end

-- SHA-256 als 32 Bytes (binaerer String)
function M.sha256(msg)
  local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
  local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

  local len = #msg
  -- Auffuellen: 0x80, Nullen, dann die Laenge in Bit als 64-Bit-Zahl
  local bits = len * 8
  msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64)
  local hi = math.floor(bits / 4294967296)
  local lo = bits % 4294967296
  msg = msg .. string.char(
    rshift(hi, 24) % 256, rshift(hi, 16) % 256, rshift(hi, 8) % 256, hi % 256,
    rshift(lo, 24) % 256, rshift(lo, 16) % 256, rshift(lo, 8) % 256, lo % 256)

  local w = {}
  for chunk = 1, #msg, 64 do
    for i = 0, 15 do
      local a, b, c, d = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
      w[i] = ((a * 256 + b) * 256 + c) * 256 + d
    end
    for i = 16, 63 do
      local v15, v2 = w[i - 15], w[i - 2]
      local s0 = bxor(rrotate(v15, 7), rrotate(v15, 18), rshift(v15, 3))
      local s1 = bxor(rrotate(v2, 17), rrotate(v2, 19), rshift(v2, 10))
      w[i] = add(w[i - 16], s0, w[i - 7], s1)
    end

    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for i = 0, 63 do
      local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local t1 = add(h, S1, ch, K[i + 1], w[i])
      local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
      local maj = bxor(band(a, b), band(a, c), band(b, c))
      local t2 = add(S0, maj)
      h, g, f, e, d, c, b, a = g, f, e, add(d, t1), c, b, a, add(t1, t2)
    end
    h0, h1, h2, h3 = add(h0, a), add(h1, b), add(h2, c), add(h3, d)
    h4, h5, h6, h7 = add(h4, e), add(h5, f), add(h6, g), add(h7, h)
  end

  local out = {}
  for _, v in ipairs({ h0, h1, h2, h3, h4, h5, h6, h7 }) do
    out[#out + 1] = string.char(rshift(v, 24) % 256, rshift(v, 16) % 256, rshift(v, 8) % 256, v % 256)
  end
  return table.concat(out)
end

function M.hex(bin)
  return (bin:gsub(".", function(c) return ("%02x"):format(c:byte()) end))
end

-- HMAC-SHA256 nach RFC 2104, Ergebnis als Hex-Text
function M.hmac(key, msg)
  if #key > 64 then key = M.sha256(key) end
  key = key .. string.rep("\0", 64 - #key)
  local ipad = key:gsub(".", function(c) return string.char(bxor(c:byte(), 0x36)) end)
  local opad = key:gsub(".", function(c) return string.char(bxor(c:byte(), 0x5c)) end)
  return M.hex(M.sha256(opad .. M.sha256(ipad .. msg)))
end

-- Vergleich, der nicht verraet, an welcher Stelle der Unterschied liegt
function M.equal(a, b)
  if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then return false end
  local diff = 0
  for i = 1, #a do diff = bor(diff, bxor(a:byte(i), b:byte(i))) end
  return diff == 0
end

return M

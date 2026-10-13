-- Testvektoren fuer crypto.lua (FIPS 180-2, RFC 4231)
local function c() package.loaded.crypto = nil return require("crypto") end

test("Crypto: SHA-256 Testvektoren", function()
  local k = c()
  eq(k.hex(k.sha256("")), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  eq(k.hex(k.sha256("abc")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  eq(k.hex(k.sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")),
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
  -- genau an den Blockgrenzen (55, 56, 64 Bytes)
  eq(k.hex(k.sha256(("a"):rep(55))), "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
  eq(k.hex(k.sha256(("a"):rep(56))), "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
  eq(k.hex(k.sha256(("a"):rep(64))), "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
end)

test("Crypto: HMAC-SHA256 nach RFC 4231", function()
  local k = c()
  eq(k.hmac(("\11"):rep(20), "Hi There"), "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
  eq(k.hmac("Jefe", "what do ya want for nothing?"),
    "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
  -- Schluessel laenger als ein Block (Testfall 6)
  eq(k.hmac(("\170"):rep(131), "Test Using Larger Than Block-Size Key - Hash Key First"),
    "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
end)

test("Crypto: Vergleich", function()
  local k = c()
  eq(k.equal("abc", "abc"), true)
  eq(k.equal("abc", "abd"), false)
  eq(k.equal("abc", "ab"), false)
  eq(k.equal(nil, "ab"), false)
end)

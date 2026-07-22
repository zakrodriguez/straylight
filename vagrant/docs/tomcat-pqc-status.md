# Tomcat PQC status

**Summary:** Tomcat (Java 17 + BouncyCastle 1.81 + Tomcat 10) cannot serve a pure
ML-DSA-65 leaf: cert + PKCS12 keystore are ready, but BC's JSSE provider can't
match an ML-DSA server cert against TLS 1.3 cipher suites.

## What works today

- EJBCA-PQC-Issuing-CA issued the cert (SERVER profile, ML-DSA-65 sig + key):
  `tomcat1:C:\PqcCerts\tomcat1-pqc.p12`, PKCS12, password `changeit`, alias
  `tomcat1`, full chain incl. EJBCA-PQC-Issuing-CA + EJBCA-PQC-Root-CA.
- Java 17 `keytool -list -v` reads the PKCS12 (raw OID `2.16.840.1.101.3.4.3.18`,
  "key of unknown size"): file is fine, stdlib doesn't recognize ML-DSA.
- BouncyCastle 1.81 jars (`bcprov`, `bctls`, `bcpkix`, `bcutil`) in `C:\Tomcat\lib\`;
  BC's JCE provider sees the keystore as ML-DSA-65 (Sig algo + KeyPair).
- `KeyStore.getInstance("PKCS12", "BC")`, `KeyManagerFactory("PKIX",
  "BCJSSE").init(ks, pw)`, and `SSLContext.getInstance("TLSv1.3", "BCJSSE")`
  work; the `HttpsServer` listens and parses a TLS 1.3 ClientHello.

## What doesn't work

The handshake aborts server-side immediately after the ClientHello:

```
org.bouncycastle.tls.TlsFatalAlert: handshake_failure(40);
[server #1 @70e516d0] found no selectable cipher suite among the 3
offered: [{0x13,0x02}(TLS_AES_256_GCM_SHA384),
          {0x13,0x03}(TLS_CHACHA20_POLY1305_SHA256),
          {0x13,0x01}(TLS_AES_128_GCM_SHA256)]
```

TLS 1.3 cipher suites (AEAD + KDF) are independent of the cert sig algo, yet
`AbstractTlsServer.getSelectedCipherSuite` rejects all three: BC 1.81's
cert-vs-suite filter treats ML-DSA leaves as un-pairable with any bundled
TLS 1.3 suite, and neither `jdk.tls.signatureSchemes=mldsa65,...` nor
`org.bouncycastle.jsse.server.signature_schemes=mldsa65,...` is honored.

## What was tried

1. `PqcHttpsTest.java` — `SSLContext.getInstance("TLS", "BCJSSE")` (any TLS
   version), default sig schemes: 30 client cipher suites offered, 0 matched,
   same handshake_failure(40).
2. `PqcHttpsTest2.java` — `SSLContext.getInstance("TLSv1.3", "BCJSSE")`,
   `SSLParameters.setProtocols(["TLSv1.3"])`, explicit sig-scheme JVM props:
   3 offered, 0 matched.
3. JVM args (none changed the cipher-suite filter):
   - `-Djdk.tls.namedGroups=X25519MLKEM768,x25519,secp256r1`
   - `-Djdk.tls.signatureSchemes=mldsa65,...`
   - `-Dorg.bouncycastle.jsse.{client,server}.signature_schemes=mldsa65,...`

## Paths forward

1. **Wait for BC 1.82+.** Roadmap (<https://www.bouncycastle.org/>) includes
   ongoing TLS-PQC work; retest when server-side ML-DSA cert serving ships.
2. **Java 25 LTS upgrade.** JDK 25 (Sept 2025) shipped JEP 497 (ML-DSA primitives);
   `SunJSSE` wiring for ML-DSA *certs* needs verification. Install
   Temurin/Liberica/Zulu 25 alongside Java 17 on tomcat1.
3. **Front Tomcat with an OpenSSL 3.5 reverse proxy.** Most pragmatic: OpenSSL
   3.5 serves ML-DSA server-side; Tomcat backends over plain HTTP (nginx +
   ML-DSA pattern, OpenSSL `s_server` as proxy). Not Tomcat-native PQC.
4. **Use Tomcat's tomcat-native (APR/OpenSSL) connector.** TLS via native
   OpenSSL (`tomcat-native.dll` + APR,
   `org.apache.tomcat.util.net.openssl.OpenSSLImplementation`); building
   `tomcat-native` against OpenSSL 3.5 on Windows is non-trivial.

## What we shipped

- The tomcat1 PKCS12 keystore (artifact for future retries) and this document.
- tomcat1:8444 was NOT added to `validate.sh` or the `pqc-handshake` scanner
  targets — it would fail until BC fixes the filter or Java 25 / an OpenSSL proxy.

The pure-PQC headline endpoint count stays at 4 (observe1, stepca1, ejbca1,
hydra1); 5 when this resolves.

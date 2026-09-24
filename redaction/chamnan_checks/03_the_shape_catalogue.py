# ------------------ one provider or block shape per check, moved from chamnan's suite (2026-09-24)
# Each of these proves the redactor recognises a SHAPE, which is exactly the key-shaped data the
# plugin no longer carries. Run by the release's corpus step through `suite_slice.py --file`.
check("a key glued to Thai prose is still redacted",
      "<REDACTED>" in redact.scrub("// รหัสจริงคือ" + fake("sk-ant-", "api03-", "AAAAAAAAAAAAAAAAAAAA")))
check("a webhook URL whose path IS the credential is redacted",
      "<REDACTED>" in redact.scrub(
          fake("https://hooks.slack.com/services/", "T00000000/B00000000/", "X" * 24)))
check("a PGP private key block is redacted like any other private key",
      "lQOY" not in redact.scrub(
          fake("-----BEGIN PGP PRIVATE", " KEY BLOCK-----") + "\nlQOY\n"
          + fake("-----END PGP PRIVATE", " KEY BLOCK-----")))
check("an OpenSSH private key still is too",
      "b3Bl" not in redact.scrub(
          fake("-----BEGIN OPENSSH PRIVATE", " KEY-----") + "\nb3Bl\n"
          + fake("-----END OPENSSH PRIVATE", " KEY-----")))
_decoy03 = (fake("-----BEGIN RSA PRIVATE", " KEY-----") + "\n"
            "# NOTE: keys are terminated with " + fake("-----END RSA PRIVATE", " KEY-----") + "\n"
            "MIIBOgIBAAJBAKj34REALKEYDATA\nREALKEYDATA==\n"
            + fake("-----END RSA PRIVATE", " KEY-----"))
check("A DECOY END MARKER DOES NOT LEAVE THE REAL KEY BODY EXPOSED",
      "REALKEYDATA" not in redact.scrub(_decoy03))
_gcp03 = ('{\n  "type": "service_account",\n  "project_id": "my-project-123456",\n'
          '  "private_key_id": "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0",\n'
          '  "private_key": "' + fake("-----BEGIN PRIVATE", " KEY-----") + '\\nMIIabc123\\n'
          + fake("-----END PRIVATE", " KEY-----") + '\\n",\n'
          '  "client_email": "deploy@my-project-123456.iam.gserviceaccount.com",\n'
          '  "auth_uri": "https://accounts.google.com/o/oauth2/auth",\n'
          '  "token_uri": "https://oauth2.googleapis.com/token",\n'
          '  "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs"\n}')
_gcp_out03 = redact.scrub(_gcp03)
check("A SERVICE-ACCOUNT KEY LOSES ITS SECRETS AND KEEPS ITS PUBLIC ENDPOINTS",
      _gcp_out03.count("<REDACTED>") == 2
      and "accounts.google.com/o/oauth2/auth" in _gcp_out03
      and "oauth2.googleapis.com/token" in _gcp_out03
      and "googleapis.com/oauth2/v1/certs" in _gcp_out03)
for _l03, _t03 in (("rotation-era refresh", fake("xox", "e-1-", "A1b2C3d4E5f6G7h8I9j0K1l2M3n4")),
                   ("rotation-era access", fake("xox", "e.", "xox", "p-1-", "A1b2C3d4E5f6G7h8I9j0K1l2")),
                   ("the older bot token", fake("xox", "b-1-", "A1b2C3d4E5f6G7h8I9j0K1l2"))):
    check(f"...and a Slack token is redacted whichever era it is from: {_l03}",
          redact.PLACEHOLDER in redact.scrub(f"token: {_t03}"))

# serierl

Vibecoded Erlang serial communication app.

This project was created because the existing Erlang serial library has a shady license and its GitHub repository is archived and yellow is ugly. Furthermore their github alternative is not interesting. Screw microsoft but nah.

To ensure minimal restrictions and alignment with the ecosystem, it uses the Apache License 2.0, matching Erlang/OTP.

## Building

The project is built using standard standard Rebar3 tooling:

```bash
rebar3 compile
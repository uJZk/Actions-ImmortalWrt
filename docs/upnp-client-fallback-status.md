# UPnP internal-client fallbacks

The miniupnpd feed receives source patches for empty internal-client addresses.
In non-strict mode, IPv4 AddPortMapping uses the HTTP peer's IPv4 address;
AddPinhole uses the native IPv6 peer's address. IPv4-mapped IPv6 peers can use
the IPv4 fallback, while native IPv6 peers cannot supply an IPv4 fallback and
IPv4 peers cannot supply an IPv6 fallback. The existing pinhole authorization
and port checks still apply. Strict builds retain the upstream rejection.

Local checks applied both patches in sequence against miniupnpd 2.3.11, checked
shell syntax, and compiled extracted fallback and pinhole verification logic in
strict and non-strict modes. These checks are not a full firmware build or a
router test. After release, test empty, missing and explicit client addresses,
IPv4-mapped and native IPv6 peers, pinhole authorization, and external access.
The factory defaults disable IPv6 pinholes; enabling them is required for the
IPv6 runtime test.

# Country and network-owner data

`countries.bin` and `owners.bin` say which country an internet address is in,
and which network it belongs to. Connections uses them to name the servers your
apps talk to, entirely on your Mac.

They're converted from DB-IP's free **IP to Country Lite** and **IP to ASN Lite**
databases, for the month in `MONTH`:

> IP geolocation by [DB-IP](https://db-ip.com), licensed under the
> [Creative Commons Attribution 4.0 International License](https://creativecommons.org/licenses/by/4.0/).

The data is DB-IP's. NetworkMonitor changed only its format: it merged
neighbouring ranges with the same answer, and keyed IPv6 ranges on their first
64 bits.

`./Scripts/geodata.sh` downloads the current month and rebuilds both files.
They're committed, not built, because DB-IP removes each month's files once the
next is out.

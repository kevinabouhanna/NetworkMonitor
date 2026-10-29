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

`world.bin` is the Connections map: every country's outline, from
[Natural Earth](https://www.naturalearthdata.com)'s 1:10m countries, which are in the
public domain. NetworkMonitor projected them with Equal Earth, simplified them to
within about 11 km, and added dots for 11 places Natural Earth draws inside another
country. `./Scripts/mapdata.sh` rebuilds it.

`./Scripts/geodata.sh` downloads the current month and rebuilds both DB-IP files.
They're committed, not built, because DB-IP removes each month's files once the
next is out.

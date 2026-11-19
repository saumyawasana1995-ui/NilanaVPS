# Nilana VLESS v1.1.0 - network fix, speed, and adult-site exit

## Apply (as root on the VPS, nothing is lost)

    bash install-vless.sh --update

Users, links and settings are kept. The panel keeps working (it only needs the stats API, which is unchanged).
Run it again any time; it is safe to repeat.

## 1. "Connected but no internet" - what was changed

| Problem | Fix |
|---|---|
| Xray looked up every site through the VPS's own resolver. If that hiccups, every page hangs while the VPN still shows "connected". | Xray now has its own cached DNS-over-HTTPS (1.1.1.1, 8.8.8.8, system DNS as last resort). Stale answers are served while it refreshes. |
| Sites that return IPv6 addresses on a VPS with no working IPv6 route | Xray resolves IPv4 only. |
| Large packets dropped somewhere on the path (pages half-load) | `tcp_mtu_probing=1` |
| The VPS's own DNS (systemd-resolved) | Pinned to 1.1.1.1 / 8.8.8.8 with 9.9.9.9 fallback. |
| Having to restart services by hand | `nilana-netwatch` checks every minute: internet, DNS, HTTPS, Xray. It repairs in steps: flush DNS -> restart resolved -> re-apply network -> restart Xray -> reboot only after 15 minutes of no internet (max once per 6 h). After a recovery it restarts Xray once to drop stale connections. |

Every failure writes a snapshot (routes, DNS, memory, conntrack, kernel messages) to
`/var/log/nilana-netwatch.log`. If the problem comes back, send me that log and we will know the real cause.

Commands:

    nilana-netwatch --now     # check now
    nilana-netwatch --diag    # every check + snapshot
    tail -50 /var/log/nilana-netwatch.log
    systemctl list-timers nilana-netwatch.timer

## 2. Speed and ping

Applied: BBR + fq congestion control, bigger TCP buffers for a long-distance link, tuned backlog and keepalive.
Check: `sysctl net.ipv4.tcp_congestion_control` should say `bbr`.

This improves throughput and recovery from packet loss. It cannot reduce ping: ping is the distance
between you and the server. Sri Lanka -> Sydney is one of the longest paths there is. A server in
Mumbai/Hyderabad (Oracle regions) or Singapore will have a far lower ping.
Oracle fixes the free-tier home region when the account is created, so that means a new Oracle account
or a small server at another provider. Run `install-vless.sh` there and use that server's link.

## 3. Adult sites (Australia blocks them)

Since 9 March 2026 Australian law requires age checks, and the big adult sites block Australian IP
addresses instead. Your Sydney VPS has an Australian IP, so the sites refuse it. Cloudflare WARP and
most "free VPN" tricks will not help from Sydney because they give an Australian address too.
The traffic must leave from another country.

**Permanent solution A (best): use a server outside Australia for everything** (see section 2).

**Permanent solution B: keep Sydney, send only adult-site domains through another country.**

1. Install `install-vless.sh` on a second server in another country (Singapore, India, ...) and create a user there.
2. Copy that user's `vless://...` link (menu option 6 on the second server).
3. On the Sydney VPS:

       vless exit set 'vless://...the link...'
       vless exit test        # must print a country other than AU

   (or `vless` -> option 14). A plain `socks5://user:pass@host:port` proxy also works.

Only adult domains (the built-in `geosite:category-porn` list plus `/etc/nilana-vless/adult-domains.txt`) take
the second hop; everything else stays fast and direct. If a site loads but its videos don't, add the video/CDN
domain to `adult-domains.txt` (one per line) and run `vless exit status` / `nilana-vless render`.
Remove with `vless exit off`.

Notes: the extra hop adds latency to those sites (Sri Lanka -> Sydney -> exit). The second server's own
provider rules and local laws still apply to what you do there. Use REALITY mode on the second server (the default);
self-signed `ws` links are rejected by current Xray.

## If Xray rejects a new setting

The config generator tests the config with `xray run -test` and steps down: full -> without the domain list ->
without DNS cache -> the old v1.0 layout. If that happens `vless render` prints `Note: ... level N of 3`;
run `vless` -> option 11 (Update Xray) to get a newer build.

## Uninstall

`vless` -> option 12 removes everything including the watchdog and tuning files.

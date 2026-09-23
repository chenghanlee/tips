# Ten-query embedding relevance gate for issue #54. See Tips.SearchProbe.
#
#     mix run scripts/search_probe.exs --validate
#     TIPS_REAL_PROVIDERS=1 mix run scripts/search_probe.exs --real --output tmp/search-probe-54.json
System.halt(Tips.SearchProbe.main(System.argv()))

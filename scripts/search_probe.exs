# Ten-query embedding relevance gate for issues #54 (v1) and #234 (v2). See Tips.SearchProbe.
#
#     mix run scripts/search_probe.exs --validate [--gate v2]
#     TIPS_REAL_PROVIDERS=1 mix run scripts/search_probe.exs --real --gate v2 --output PATH
System.halt(Tips.SearchProbe.main(System.argv()))

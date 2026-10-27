{ interfaceName }:
''
  table inet machine-ssh {
  	chain input {
  		type filter hook input priority filter - 10; policy accept;
  		tcp dport 22 iifname != { "${interfaceName}", "lo" } drop
  	}
  }
''

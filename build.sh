#!/bin/bash
set -e

singvers=('1.8.14')

cfg_ips=$1
cfg_sites=$2

singbox="$(which sing-box)"
[ "$singbox" == '' ] && [ -f './sing-box' ] && singbox='./sing-box'
if [ "$singbox" != '' ]; then
  sing_curver="$($singbox version | head -n 1 | cut -d ' ' -f 3)"
  [[ "${singvers[@]}" =~ "$sing_curver" ]] || singbox=''
fi

concat_rule_json()
{
  local result='{"version": 1,"rules": [{}]}'
  
  for ruleSetItem in "$@"
  do
    #*NOTE #1:
    # jq += required two values to be of same type;
    # However in sing-box, when the value to a key is an array of single item(usually string),
    # the value can be that single item(string) instead of the array containing that string.
    # We are adding/merging 2 arrays together here, so we need to convert that single item into an array containing it.
    ##Therefore we use:
    # $jsonstring | jq 'with_entries(if .value | type == "string" then .value |= [.] else . end)'
    
    #*NOTE #2:
    # We do not use jq --jsonargs here because our json rule can be too long/big,
    # and --jsonargs/--args could not handle it.
    # Therefore we output our json rule to a file, and use --slurpfile to read it.
    
    #*NOTE #3:
    # Using jq to add(+=) 2 items which contains the same key,
    # will result in value of that key in item 2 replacing instead of adding to that value in item 1
    # Thus we need to add the values of those same keys, instead of add the parent level items
    
    local newrule_file="temp.json"
    echo "$ruleSetItem" | jq '.rules[0]' | jq 'with_entries(if .value | type == "string" then .value |= [.] else . end)' > "$newrule_file"
    
    if $(jq 'has("ip_cidr")' "$newrule_file"); then
      result="$(echo "$result" | jq --slurpfile jqnewrule "$newrule_file" '.rules[0].ip_cidr += $jqnewrule[0].ip_cidr')"
    fi
    if $(jq 'has("domain")' "$newrule_file"); then
      result="$(echo "$result" | jq --slurpfile jqnewrule "$newrule_file" '.rules[0].domain += $jqnewrule[0].domain')"
    fi
    if $(jq 'has("domain_suffix")' "$newrule_file"); then
      result="$(echo "$result" | jq --slurpfile jqnewrule "$newrule_file" '.rules[0].domain_suffix += $jqnewrule[0].domain_suffix')"
    fi
    if $(jq 'has("domain_keyword")' "$newrule_file"); then
      result="$(echo "$result" | jq --slurpfile jqnewrule "$newrule_file" '.rules[0].domain_keyword += $jqnewrule[0].domain_keyword')"
    fi
    if $(jq 'has("domain_regex")' "$newrule_file"); then
      result="$(echo "$result" | jq --slurpfile jqnewrule "$newrule_file" '.rules[0].domain_regex += $jqnewrule[0].domain_regex')"
    fi
    
    rm "$newrule_file"
  done
  
  echo $result
}

geo2rule()
{
  #geotype=("geoip"|"geosite")
  local geotype="$1"
  #example: geolist='["cn","us","jp"]'
  local geolist="$2"
  local result='{"version": 1,"rules": [{}]}'
  
  readarray -t geoitems < <( echo "$geolist" | jq -rc '.[]')
  [ $? -ne 0 ] && exit 1
  for geoitem in "${geoitems[@]}"
  do
    $singbox $geotype export "${geoitem}"
    [ $? -ne 0 ] && exit 1
    
    local geo_rules="$(cat "${geotype}-${geoitem}.json")"
    
    result="$(concat_rule_json "$result" "$geo_rules")"
    rm "${geotype}-${geoitem}.json"
  done
  
  echo $result
}

build_rule_file()
{
  local geotype="$1"
  local rule_cfg="$2"
  
  local filename="$(echo "$rule_cfg" | jq -r '.tag')"
  if [ "$filename" == "null" ]; then
    echo "ip json file format wrong: no tag/filename"
    exit 1
  fi
  echo "building ${filename}.srs"

  local geo_list="$(echo "$rule_cfg" | jq ".rules.${geotype}")"
   #[ $? -ne 0 ] && >&2 echo "Err: does not contain rules.${geotype} field in .json" && exit 1
  [ "$geo_list" == "null" ] && geo_list=''
  local geo_rules="$(geo2rule "${geotype}" "${geo_list}")"
  #>&2 echo "DEBUG#Z"
  
  local other_rules="$(echo "$rule_cfg" | jq ".rules | del(.${geotype})")"
  other_rules="$(echo '{"version": 1,"rules": [{}]}' | jq --argjson jqnewrule "$other_rules" '.rules[0] += $jqnewrule')"
  
  local result="$(concat_rule_json "$geo_rules" "$other_rules")"
  
  echo "${result}" > "./${filename}.json"
  $singbox rule-set compile "${filename}.json"
  [ "$DEBUG" == "1" ] || rm "${filename}.json"
  
  echo "${filename}.srs is built"
}

build_ruleset()
{
  local rule_cfg
  local geotype="$1"
  local ruleset_cfg="$2"
  
  jq -rc '.[]' "$ruleset_cfg" | while read -r rule_cfg; do
    build_rule_file "$geotype" "$rule_cfg"
  done
}

manual_setup_sb()
{
  local singver="${singvers[0]}"
  wget "https://github.com/SagerNet/sing-box/releases/download/v${singver}/sing-box-${singver}-linux-amd64.tar.gz"
  tar -xvzf ./sing-box-${singver}-linux-amd64.tar.gz
  mv ./sing-box-${singver}-linux-amd64/sing-box .
  rm -rf ./sing-box-*
  chmod u+x ./sing-box
  singbox='./sing-box'
}

[ "$singbox" == '' ] && manual_setup_sb
build_ruleset 'geoip' $cfg_ips
build_ruleset 'geosite' $cfg_sites

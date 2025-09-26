#!/bin/bash
# set -e


cfg_ips=$1
cfg_sites=$2

#singvers: to avoid bugs in latest release of sing-box, only use the versions we verified to work
singvers=('1.11.15' '1.10.7' '1.10.5' '1.10.3')
empty_ruleset='{"version": 2, "rules": [{}]}'
custom_ruleset_resc=('geolocation-!cn' 'microsoft' 'sites2-new_direct')
singbox=''



download_singbox()
{
  local singver="${singvers[0]}"
  
  if [ "$DEBUG" == "1" ]; then
    wget "https://github.com/SagerNet/sing-box/releases/download/v${singver}/sing-box-${singver}-linux-amd64.tar.gz"
  else
    wget "https://github.com/SagerNet/sing-box/releases/download/v${singver}/sing-box-${singver}-linux-amd64.tar.gz" > /dev/null 2>&1
  fi
  
  tar -xvzf ./sing-box-${singver}-linux-amd64.tar.gz
  mv ./sing-box-${singver}-linux-amd64/sing-box .
  rm -rf ./sing-box-*
}

initialize_singbox()
{
  singbox="$(which sing-box)"
  [ "$singbox" == '' ] && [ -s './sing-box' ] && singbox='./sing-box'
  if [ "$singbox" != '' ]; then
    local sing_curver="$($singbox version | head -n 1 | cut -d ' ' -f 3)"
    [[ "${singvers[@]}" =~ "$sing_curver" ]] || singbox=''
  fi
  if [ "$singbox" == '' ]; then
    download_singbox
    chmod u+x ./sing-box
    singbox='./sing-box'
  fi
}



## TODO: try "sing-box merge" from sing-box 1.11.0

# rule_json_addition:
# parameters: any number of variables of json string
# parameter form: [{"ip_cidr":[...],"domain":[],...}]
# return result: for all the json string parameters, concatenate(add) them together and return the result string
# result form: '{"version": 2, "rules": [{"ip_cidr":[...],"domain":[],...}]}'
rule_json_addition()
{
  local result="${empty_ruleset}"
  
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
    # and --jsonargs/--args could not handle such load.
    # We use --slurpfile instead, which is able to handle big load of data.
    # --slurpfile works with an input string and a json file, so we output json rule to a file for it.
    
    #*NOTE #3:
    # Using jq to add(+=) 2 items which contains the same key,
    # will result in value of that key in item 2 replacing instead of adding to that value in item 1
    # Thus we need to add the values of those same keys, instead of add the parent level items
    
    local temprule_file="temp.json"
    echo "$ruleSetItem" | jq '.rules[0]' | jq 'with_entries(if .value | type == "string" then .value |= [.] else . end)' > "$temprule_file"
    
    if $(jq 'has("ip_cidr")' "$temprule_file"); then
      result="$(echo "$result" | jq --slurpfile jqnewrule "$temprule_file" '.rules[0].ip_cidr += $jqnewrule[0].ip_cidr')"
    fi
    if $(jq 'has("domain")' "$temprule_file"); then
      result="$(echo "$result" | jq --slurpfile jqnewrule "$temprule_file" '.rules[0].domain += $jqnewrule[0].domain')"
    fi
    if $(jq 'has("domain_suffix")' "$temprule_file"); then
      result="$(echo "$result" | jq --slurpfile jqnewrule "$temprule_file" '.rules[0].domain_suffix += $jqnewrule[0].domain_suffix')"
    fi
    if $(jq 'has("domain_keyword")' "$temprule_file"); then
      result="$(echo "$result" | jq --slurpfile jqnewrule "$temprule_file" '.rules[0].domain_keyword += $jqnewrule[0].domain_keyword')"
    fi
    if $(jq 'has("domain_regex")' "$temprule_file"); then
      result="$(echo "$result" | jq --slurpfile jqnewrule "$temprule_file" '.rules[0].domain_regex += $jqnewrule[0].domain_regex')"
    fi
    
    rm "$temprule_file"
  done
  
  echo $result
}

# rule_json_subtraction:
# parameters: two variables of json string, $1 and $2
# return result: subtract(filter out) the content of second json($2) from first json($1), and return the rest of the first json
# in heuristic terms, $result = $1 - $2
# parameter & result form: '{"version": 2, "rules": [{"ip_cidr":[...],"domain":[],...}]}'
rule_json_subtraction()
{
  #*NOTE #1#2#3: see NOTEs in rule_json_addition()
  local result="$(echo "$1" | jq '.' | jq 'with_entries(if .value | type == "string" then .value |= [.] else . end)')"
  local temprule_file="temp.json"
  echo "$2" | jq '.' | jq 'with_entries(if .value | type == "string" then .value |= [.] else . end)' > "$temprule_file"
  
  if $(jq '(.rules[0]? | has("ip_cidr"))' "$temprule_file"); then
    result="$(echo "$result" | jq --slurpfile jqnewrule "$temprule_file" '.rules[0].ip_cidr |= map(select(. as $d | $jqnewrule[0].rules[0].ip_cidr | index($d) | not))')"
  fi
  if $(jq '(.rules[0]? | has("domain"))' "$temprule_file"); then
    result="$(echo "$result" | jq --slurpfile jqnewrule "$temprule_file" '.rules[0].domain |= map(select(. as $d | $jqnewrule[0].rules[0].domain | index($d) | not))')"
  fi
  if $(jq '(.rules[0]? | has("domain_suffix"))' "$temprule_file"); then
    result="$(echo "$result" | jq --slurpfile jqnewrule "$temprule_file" '.rules[0].domain_suffix |= map(select(. as $d | $jqnewrule[0].rules[0].domain_suffix | index($d) | not))')"
  fi
  if $(jq '(.rules[0]? | has("domain_keyword"))' "$temprule_file"); then
    result="$(echo "$result" | jq --slurpfile jqnewrule "$temprule_file" '.rules[0].domain_keyword |= map(select(. as $d | $jqnewrule[0].rules[0].domain_keyword | index($d) | not))')"
  fi
  if $(jq '(.rules[0]? | has("domain_regex"))' "$temprule_file"); then
    result="$(echo "$result" | jq --slurpfile jqnewrule "$temprule_file" '.rules[0].domain_regex |= map(select(. as $d | $jqnewrule[0].rules[0].domain_regex | index($d) | not))')"
  fi
    
  rm "$temprule_file"
  echo $result
}

geo2rule()
{
  #geotype=("geoip"|"geosite")
  local geotype="$1"
  #example: geolist='["cn","us","jp"]'
  local geolist="$2"
  local result="${empty_ruleset}"
  
  readarray -t geoitems < <( echo "$geolist" | jq -rc '.[]')
  [ $? -ne 0 ] && echo "Error reading listed items: ${geotype}-${geolist}" >&2 && exit 1
  for geoitem in "${geoitems[@]}"
  do
    # re-use ${geotype}-${geoitem} if already exist
    [ -s "${geotype}-${geoitem}.json" ] || $singbox $geotype export "${geoitem}"
    [ $? -ne 0 ] && exit 1
    
    local geo_rules="$(cat "${geotype}-${geoitem}.json")"
    
    result="$(rule_json_addition "$result" "$geo_rules")"
    # donot delete "${geotype}-${geoitem}.json" since we may re-use
    # rm "${geotype}-${geoitem}.json"
  done
  
  echo $result
}

build_rule_file()
{
  local geotype="$1"
  local rule_cfg="$2"
  #mode: ['dryrun'|'json'|'srs']
  local mode="$3"
  [ "$mode" == '' ] && mode='srs'
  
  
  local filename="$(echo "$rule_cfg" | jq -r '.tag')"
  if [ "$filename" == "null" ]; then
    echo "ip json file format wrong: no tag/filename" >&2
    exit 1
  fi
  [ "$DEBUG" == "1" ] && echo "building ${filename} in mode: ${mode}"

  local geo_list="$(echo "$rule_cfg" | jq ".rules.${geotype}")"
   #[ $? -ne 0 ] && >&2 echo "Err: does not contain rules.${geotype} field in .json" && exit 1
  [ "$geo_list" == "null" ] && geo_list=''
  local geo_rules="$(geo2rule "${geotype}" "${geo_list}")"
  #>&2 echo "DEBUG#Z"
  
  local other_rules="$(echo "$rule_cfg" | jq ".rules | del(.${geotype})")"
  other_rules="$(echo "${empty_ruleset}" | jq --argjson jqnewrule "$other_rules" '.rules[0] += $jqnewrule')"
  
  local result="$(rule_json_addition "$geo_rules" "$other_rules")"
  
  if [ "$mode" == 'dryrun' ]; then
    echo $result
  else
    echo "${result}" > "./${filename}.json"
    if [ ! -s "./${filename}.json" ]; then
      echo "build ${filename}.json failed" >&2
    elif  [ "$mode" == 'json' ] || [ "$DEBUG" == "1" ]; then
      echo "${filename}.json is built"
    fi
    
    if [ "$mode" == "srs" ]; then
      [ "$DEBUG" == "1" ] && echo "building ${filename}.srs"
      $singbox rule-set compile "${filename}.json"
      [ -s "./${filename}.srs" ] && echo "${filename}.srs is built" || echo "build ${filename}.srs failed" >&2
    fi
  fi
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

## TODO: for geosite:cn, use original v2fly/domain-list-community version, instead of loyalsoldier version
## loyalsoldier's geosite:cn adds google-cn and apple-cn on top of original version
## official sing-box geosite.db is made from v2fly/domain-list-community, link: https://github.com/SagerNet/sing-geosite/
build_filtered_ruleset()
{
  [[ "${1}" == "site"* ]] && ruletag1="${1}" || ruletag1="geosite_${1}"
  [[ "${2}" == "site"* ]] && ruletag2="${2}" || ruletag2="geosite_${2}"
  ruletag_result="geosite_${3}"
  
  if [ ! -s "${ruletag1}.json" ]; then
    local cfg1="{\"tag\": \"${ruletag1}\", \"rules\": {\"geosite\": [\"${1}\"]}}"
    build_rule_file 'geosite' "$cfg1" 'json'
  fi
  if [ ! -s "${ruletag2}.json" ]; then
    local cfg2="{\"tag\": \"${ruletag2}\", \"rules\": {\"geosite\": [\"${2}\"]}}"
    build_rule_file 'geosite' "$cfg2" 'json'
  fi
  
  echo "building ${ruletag_result}.json"
  rule1="$(cat "${ruletag1}.json")"
  rule2="$(cat "${ruletag2}.json")"
  rule_json_subtraction "$rule1" "$rule2" > "${ruletag_result}.json"
  [ -s "${ruletag_result}.json" ] && echo "${ruletag_result}.json is built" || echo "build ${ruletag_result}.json failed" >&2
}

build_customized_ruleset()
{
## TODO: optimize rule-sets, by removing contents already checked
<< TEMP
  # custom_ruleset #1
  # removes geosite:microsoft from geosite:geolocation-!cn
  # creates a new ruleset [geosite_!cn_filter~microsoft.srs] as result
  local custom_ruleset1='!cn_filter~microsoft'
  build_filtered_ruleset 'geolocation-!cn' 'microsoft' "${custom_ruleset1}"
  [ "$DEBUG" == "1" ] && echo "building geosite_${custom_ruleset1}.srs"
  $singbox rule-set compile "geosite_${custom_ruleset1}.json"

  # custom_ruleset #2
  # removes geosite:google-cn from sites2-new_direct(->contains geosite:cn ->contains geosite:google-cn)
  # changes the result to be the new&modified [sites2-new_direct.srs]
  local custom_ruleset2='direct_filter~google-cn'
  build_filtered_ruleset 'sites2-new_direct' 'google-cn' "${custom_ruleset2}"
  [ "$DEBUG" == "1" ] && echo "geosite_${custom_ruleset2}.srs"
  $singbox rule-set compile "geosite_${custom_ruleset2}.json"
  rm "sites2-new_direct.srs"
  mv "geosite_${custom_ruleset2}.srs" "sites2-new_direct.srs"
TEMP

  # custom_ruleset #3
}



initialize_singbox
build_ruleset 'geoip' $cfg_ips
build_ruleset 'geosite' $cfg_sites
build_customized_ruleset


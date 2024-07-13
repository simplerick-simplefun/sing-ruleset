#!/bin/bash
set -e

cfg_ips=$1
cfg_sites=$2
output_dir=$3
[ ! -f "$output_dir" ] && output_dir='.'
[[ "$(which sing-box)" == "" ]] && alias sing-box='./sing-box'
ll


concat_rule_json()
{
  local result='{"version": 1,"rules": [{}]}'
  
  for ruleSetItem in "$@"
  do
    local newrule_file="temp.json"
    echo "$ruleSetItem" | jq '.rules[0]' | jq 'with_entries(if .value | type == "string" then .value |= [.] else . end)' > "$newrule_file"
    
    if $(jq 'has("ip_cidr")' "$newrule_file"); then
      result=$(echo "$result" | jq --slurpfile jqnewrule "$newrule_file" '.rules[0].ip_cidr += $jqnewrule[0].ip_cidr')
    fi
    if $(jq 'has("domain")' "$newrule_file"); then
      result=$(echo "$result" | jq --slurpfile jqnewrule "$newrule_file" '.rules[0].domain += $jqnewrule[0].domain')
    fi
    if $(jq 'has("domain_suffix")' "$newrule_file"); then
      result=$(echo "$result" | jq --slurpfile jqnewrule "$newrule_file" '.rules[0].domain_suffix += $jqnewrule[0].domain_suffix')
    fi
    if $(jq 'has("domain_keyword")' "$newrule_file"); then
      result=$(echo "$result" | jq --slurpfile jqnewrule "$newrule_file" '.rules[0].domain_keyword += $jqnewrule[0].domain_keyword')
    fi
    if $(jq 'has("domain_regex")' "$newrule_file"); then
      result=$(echo "$result" | jq --slurpfile jqnewrule "$newrule_file" '.rules[0].domain_regex += $jqnewrule[0].domain_regex')
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
    sing-box $geotype export "${geoitem}"
    [ $? -ne 0 ] && exit 1
    
    local geo_rules=$(cat "${geotype}-${geoitem}.json")
    
    result=$(concat_rule_json "$result" "$geo_rules")
    rm "${geotype}-${geoitem}.json"
  done
  
  echo $result
}

build_rule_file()
{
  local geotype="$1"
  local rule_cfg="$2"
  
  local filename=$(echo "$rule_cfg" | jq -r '.tag')
  if [ "$filename" == "null" ]; then
    echo "ip json file format wrong: no tag/filename"
    exit 1
  fi
  echo "building ${filename}.srs"
  
  local geo_list=$(echo "$rule_cfg" | jq ".rules.${geotype}")
  [ $? -ne 0 ] && echo "Err: does not contain rules.${geotype} field in .json" && exit 1
  local geo_rules=$(geo2rule "${geotype}" "${geo_list}")
  
  local other_rules=$(echo "$rule_cfg" | jq ".rules | del(.${geotype})")
  other_rules=$(echo '{"version": 1,"rules": [{}]}' | jq --argjson jqnewrule "$other_rules" '.rules[0] += $jqnewrule')
  
  local result=$(concat_rule_json "$geo_rules" "$other_rules")
  
  echo "${result}" > "${output_dir}/${filename}.json"
  sing-box rule-set compile "${filename}.json"
  [ "$DEBUG" == "1" ] || rm "${filename}.json"
  
  echo "${filename}.srs is built"
}

build_ip()
{
  local rule_cfg
  jq -c '.[]' $1 | while read rule_cfg; do
    build_rule_file 'geoip' "$rule_cfg"
  done
}

build_site()
{
  local rule_cfg
  jq -rc '.[]' $1 | while read -r rule_cfg; do
    build_rule_file 'geosite' "$rule_cfg"
  done
}

build_ip $cfg_ips
build_site $cfg_sites

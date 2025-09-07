#!/bin/bash
# Quick script to generate self-signed ecdsa certificate with extensions for SANs
set -e 

usage='
usage: ./script <server fqdn> [keyfile] [cert lifetime days] [output certificate file]

  Default key file is to generate a new one in current directory
  Default lifetime is 1000 years
  Default cert out file is current directory
'

requestedDNSName=$1
if [[ -z $requestedDNSName ]]
then
    echo "Must provide server DNS name as first argument" >&2
    echo "$usage"
    exit 1
fi

if [[ -n $2 ]]
then
    keyFile=$2
else
    keyFile="ecdsa-key.pem"
fi

if [[ -n $3 ]]
then
    certLifetime=$3
else
    certLifetime="365000" # 1000 years
fi

if [[ -n $4 ]]
then
    certFile="$4"
else
    certFile="ecdsa-cert.pem"
fi

csrFile="ecdsa.csr"
reqConfFile="ecdsa-req.conf"
reqConf='[ req ]
default_bits       = 256
default_md         = sha384
distinguished_name = req_distinguished_name
req_extensions     = req_ext
prompt             = yes

[ req_distinguished_name ]
# These fields will prompt
countryName                     = Country Name (2 letter code)
countryName_default             = US
countryName_min                 = 2
countryName_max                 = 2

stateOrProvinceName             = State or Province Name (full name)
stateOrProvinceName_default     = 

localityName                    = Locality Name (e.g. city)
localityName_default            = 

organizationName                = Organization Name (e.g. company)
organizationName_default        = 

organizationalUnitName          = Organizational Unit (e.g. department)
organizationalUnitName_default  = 

emailAddress                    = Email Address
emailAddress_max                = 64

# Fields used from script input
commonName                      = Common Name (e.g. FQDN)
commonName_default              = '$requestedDNSName'
commonName_max                  = 64

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1   = '$requestedDNSName'
'

# shellcheck disable=SC2329
cleanup()
{
  echo -e "\nEncountered error, cleaning up"
  if [[ $newKeyGenerated == true ]]
  then
    rm -f "$keyFile" 2>/dev/null
  fi
  rm -f "$reqConfFile" 2>/dev/null
  rm -f "$csrFile" 2>/dev/null
  rm -f "$certFile" 2>/dev/null
  exit
}

trap cleanup 1 2 3 6

# Temp write to disk
echo "$reqConf" > $reqConfFile

# Allow using existing keys
if ! [[ -f $keyFile ]]
then
    newKeyGenerated='true'
    openssl ecparam -name prime256v1 -genkey -noout -out "$keyFile"
fi

openssl req -new -key "$keyFile" -out "$csrFile" -config "$reqConfFile"

openssl x509 -req -in "$csrFile" -signkey "$keyFile" -sha384 -out "$certFile" -days "$certLifetime" -extfile "$reqConfFile" -extensions req_ext

rm -f "$csrFile"
rm -f "$reqConfFile"
echo "Certificate successfully generated at $certFile using key at $keyFile"

exit 0

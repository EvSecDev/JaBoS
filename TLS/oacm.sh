#!/bin/bash
##                                             ##
## Offline Asynchronous Certificate Management ##
##                                             ##

# Check for required commands
set -e
command -v openssl
command -v su
set -x

function usage {
        echo "Usage $0
Options:
  -k <keyfile>  Server private key file path
  -c <certfile> Server certificate file path (existing cert if renewing, out file if creating new)
  -a <cacert>   Certificate of authority to sign server cert (CA or intermediate)
  -A <cakey>    Key of authority to sign server cert (CA or intermediate)
  -n            Create a new certificate instead of renewing an existing one
"
}

function create_new_rsa_key {
	OUTKEY=$1
	KEYSIZE=$2

	openssl genrsa -out "$OUTKEY" "$KEYSIZE"
}

function create_csr {
	SERVERKEY=$1
	OUTCSR=$2

	openssl req -new -key "$SERVERKEY" -out "$OUTCSR" -subj "$SUBJECT"
}

function sign_with_csr {
	CSR=$1
	OUTSERVERCERT=$2

	openssl x509 -req -in "$CSR" -CA "$INTERMEDIATE_CA_CERT" -CAkey "$INTERMEDIATE_CA_KEY" \
	    -CAcreateserial -out "$OUTSERVERCERT" -days "$DAYS_VALID" -sha256 -extfile "$CONFIG_FILE" -extensions v3_req
}

# Argument parsing
while getopts 'k:c:a:A:nh' opt
do
        case "$opt" in
          'k')
            SERVERKEYFILE="$OPTARG"
            ;;
          'c')
            SERVERCERTFILE="$OPTARG"
            ;;
          'a')
            CACERTFILE="$OPTARG"
            ;;
          'A')
            CAKEYFILE="$OPTARG"
            ;;
          'n')
            createnew='true'
            ;;
          'h')
            usage
            exit 0
            ;;
        esac
done

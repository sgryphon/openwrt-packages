#!/bin/sh
set -u
ACME=/usr/lib/acme/client/acme.sh
LOG_TAG=acme-acmesh
# webroot option deprecated, use the hardcoded value directly in the next major version
WEBROOT=${webroot:-/var/run/acme/challenge}
NOTIFY=/usr/lib/acme/notify

# shellcheck source=net/acme/files/functions.sh
. /usr/lib/acme/functions.sh

# Needed by acme.sh
export CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
export NO_TIMESTAMP=1

case $1 in
get)
	set --
	[ "$debug" = 1 ] && set -- "$@" --debug

	case $keylength in
	ec-*)
		domain_dir="$state_dir/${main_domain}_ecc"
		set -- "$@" --ecc
		;;
	*)
		domain_dir="$state_dir/$main_domain"
		;;
	esac

	log info "Running ACME for $main_domain"

	if [ -e "$domain_dir" ]; then
		if [ "$staging" = 0 ] && grep -q "acme-staging" "$domain_dir/$main_domain.conf"; then
			mv "$domain_dir" "$domain_dir.staging"
			log info "Certificates are previously issued from a staging server, but staging option is diabled, moved to $domain_dir.staging."
			staging_moved=1
		else
			set -- "$@" --renew --home "$state_dir" -d "$main_domain"
			log info "$ACME $*"
			trap '$NOTIFY renew-failed;exit 1' INT
			$ACME "$@"
			status=$?
			trap - INT

			case $status in
			0)
				$NOTIFY renewed
				exit;;
			2)
				# renew skipped, ignore.
				exit
				;;
			*)
				$NOTIFY renew-failed
				exit 1
				;;
			esac
		fi
	fi

	for d in $domains; do
		set -- "$@" -d "$d"
	done
	set -- "$@" --keylength "$keylength" --accountemail "$account_email"

	if [ "$acme_server" ]; then
		set -- "$@" --server "$acme_server"
	# default to letsencrypt because the upstream default may change
	elif [ "$staging" = 1 ]; then
		set -- "$@" --server letsencrypt_test
	else
		set -- "$@" --server letsencrypt
	fi

	if [ "$days" ]; then
		set -- "$@" --days "$days"
	fi

	if [ "$dns" ]; then
		set -- "$@" --dns "$dns"
		if [ "$dalias" ]; then
			set -- "$@" --domain-alias "$dalias"
			if [ "$calias" ]; then
				log err "Both domain and challenge aliases are defined. Ignoring the challenge alias."
			fi
		elif [ "$calias" ]; then
			set -- "$@" --challenge-alias "$calias"
		fi
		if [ "$dns_wait" ]; then
			set -- "$@" --dnssleep "$dns_wait"
		fi
	elif [ "$standalone" = 1 ]; then
		set -- "$@" --standalone --listen-v6
	else
		mkdir -p "$WEBROOT"
		set -- "$@" --webroot "$WEBROOT"
	fi

	set -- "$@" --issue --home "$state_dir"

	log info "$ACME $*"
	trap '$NOTIFY issue-failed;exit 1' INT
	"$ACME" "$@" \
		--pre-hook "$NOTIFY prepare" \
		--renew-hook "$NOTIFY renewed"
	status=$?
	trap - INT

	case $status in
	0)
		ln -s "$domain_dir/$main_domain.cer" /etc/ssl/acme
		ln -s "$domain_dir/$main_domain.key" /etc/ssl/acme
		ln -s "$domain_dir/fullchain.cer" "/etc/ssl/acme/$main_domain.fullchain.cer"
		ln -s "$domain_dir/ca.cer" "/etc/ssl/acme/$main_domain.chain.cer"
		$NOTIFY issued
		;;
	*)
		if [ "$staging_moved" = 1 ]; then
			mv "$domain_dir.staging" "$domain_dir"
			log err "Staging certificate restored"
		elif [ -d "$domain_dir" ]; then
			failed_dir="$domain_dir.failed-$(date +%s)"
			mv "$domain_dir" "$failed_dir"
			log err "State moved to $failed_dir"
		fi
		$NOTIFY issue-failed
		;;
	esac
	;;
esac

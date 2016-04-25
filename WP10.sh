#!/usr/bin/env bash

WIKI=$1
CMD=$2
DIR=${WIKI}_`date +"%Y-%m-%d"`

####################################
## CONFIGURATION

# Update PATH
export PATH=$PATH:./

# Perl and sort(1) have locale issues, which can be avoided 
# by disabling locale handling entirely. 
LANG=C
export LANG

# Used by /bin/sort to store temporary files
TMPDIR=./$DIR/target
export TMPDIR

##### END CONFIGURATION
####################################

usage() 
{
    echo "Usage: WP1.sh <wikiname> <command>"
    echo "  <wikiname> - such as enwiki, frwiki, ..."
    echo "  <command>  can be 'all', 'indexes', 'counts' or 'upload'"
    exit
}

## Check command line arguments
if [ "$WIKI" = '' ]; then
  usage;
fi

case $CMD in
  indexes)   echo "Making indexes for $WIKI"  ;;
  counts)    echo "Making overall counts for $WIKI"   ;;
  upload)    echo "Upload WP1 indexes * counts to wp1.kiwix.org"   ;;
  clean)     echo "Delete target directory"   ;;
  all)       echo "Make all steps"   ;;
  *)         usage                ;;
esac

####################################
if [[ "$CMD" == "indexes" || "$CMD" == "all" ]]; then
	mkdir -p ./$DIR/target

	function pipe_query_to_xz() {
		query=$1
		file=$2
	
		echo ./$DIR/target/$file.xz
		if [ -e ./$DIR/target/$file.xz ]; then
			echo "...file already exists"
		else
			# --quick option prevents out-of-memory errors
			mysql --defaults-file=~/replica.my.cnf --quick -e "$query" -N -h ${WIKI}.labsdb ${WIKI}_p |
			 tr '\t' ' ' | # MySQL outputs tab-separated; file needs to be space-separated.
			 xz > ./$DIR/target/$file.xz
		fi
	}

	function build_namespace_indexes() {
		namespace=$1
		name=$2
	
		# XXX BEWARE: This query was imputed based on what the old program seemed to be trying to do.
		# It may not be correct; we'll see what happens later on.
		pipe_query_to_xz "SELECT page_id, page_namespace, page_title, page_is_redirect FROM page WHERE page_namespace = $namespace ORDER BY page_id ASC;" ${name}_sort_by_ids.lst
	}

	## BUILD PAGES INDEXES
	build_namespace_indexes 0 main_pages

	## BUILD TALK INDEXES
	build_namespace_indexes 1 talk_pages

	# Categories may not be needed, so to save time they are disabled by default
	## BUILD CATEGORIES INDEXES
	#build_namespace_indexes 14 categories

	## BUILD PAGELINKS INDEXES - replaced by the next two files
	#pipe_query_to_xz "SELECT pl_from, pl_namespace, pl_title FROM pagelinks;" pagelinks.lst.xz

	## BUILD PAGELINKS COUNTS
	pipe_query_to_xz "SELECT pl_from, pl_title FROM pagelinks ORDER BY pl_from ASC;" pagelinks_main_sort_by_ids.lst

	# get a list of how many times each page is linked to; only for pages that
	#	exist (pl_title=page_title)
	#	are linked to more than once (HAVING COUNT(*) > 1)
	pipe_query_to_xz "SELECT pl_title, COUNT(*) FROM page, pagelinks WHERE pl_title=page_title AND page_namespace = 0 GROUP BY pl_title HAVING COUNT(*) > 1 ORDER BY pl_title;" pagelinks.counts.lst

	## BUILD LANGLINKS INDEXES
	pipe_query_to_xz "SELECT ll_from, ll_lang, ll_title FROM langlinks ORDER BY ll_from ASC;" langlinks_sort_by_ids.lst

	## BUILD REDIRECT INDEXES
	pipe_query_to_xz "SELECT rd_from, rd_namespace, rd_title FROM redirect ORDER BY rd_from ASC;" redirects_sort_by_ids.lst

	# Find redirect targets by looking in the redirect table, falling back to
	# pagelinks if that fails.
	pipe_query_to_xz "SELECT page_title,
		    IF ( rd_from = page_id,
		        rd_title,
		    /*ELSE*/IF (pl_from = page_id,
		        pl_title,
		    /*ELSE*/
		        NULL -- Can't happen, due to WHERE clause below
		    ))
		FROM page, redirect, pagelinks
		WHERE (rd_from = page_id OR pl_from = page_id)
		    AND page_is_redirect = 1
		    AND page_namespace = 0 /* main */
		ORDER BY page_id ASC;" redirects_targets.lst # TODO does this stuff *really* need to be sorted?

	## Commented out because it's very large, but may not be needed
	## BUILD CATEGORYLINKS INDEXES
	#pipe_query_to_xz "SELECT cl_from, cl_to FROM categorylinks ORDER BY cl_from ASC;" categorylinks_sort_by_ids.lst

	## BUILD LANGLINKS COUNTS
	pipe_query_to_xz "SELECT page_title, COUNT(*) FROM page, langlinks WHERE ll_from=page_id AND page_namespace = 0 GROUP BY page_id ORDER BY page_title ASC;" langlinks.counts.lst

	## BUILD LIST OF MAIN PAGES
	pipe_query_to_xz "SELECT page_title FROM page ORDER BY page_title ASC;" main_pages.lst

fi # END if [ "$CMD" = "indexes" ];

####################################

## BUILD OVERALL COUNTS
if [[ "$CMD" = "counts" ]]; then 

  if [ ! -e ./$DIR/source/hitcounts.raw.xz ]; then
   echo 
    echo "Error: You must obtain or create the file hitcounts.raw.xz"
   echo  "Place it in the directory ./$DIR/source"
    exit
  fi

  echo ./$DIR/target/counts.lst.xz
  if [ -e ./$DIR/target/counts.lst.xz ]; then
    echo "...file already exists"
  else
    ./bin/merge_counts.pl ./$DIR/target/main_pages.lst.xz \
                          ./$DIR/target/langlinks.counts.lst.xz \
                          ./$DIR/target/pagelinks.counts.lst.xz \
                          ./$DIR/source/hitcounts.raw.xz \
     | ./bin/merge_redirects.pl ./$DIR/target/redirects_targets.lst.xz \
     | sort -T$TMPDIR -t " "\
     | ./bin/merge_tally.pl \
     | xz > ./$DIR/target/counts.lst.xz
  fi
fi 

if [[ "$CMD" = "upload" || "$CMD" == "all" ]]; then
  echo "Upload $DIR to wp1.kiwix.org"
  lftp -e "mirror -R $DIR $DIR; bye" -u `cat ftp.credentials` wp1.kiwix.org
fi

if [[ "$CMD" = "clean" || "$CMD" == "all" ]]; then
  echo "Delete directory $DIR"
  rm -rf $DIR
fi

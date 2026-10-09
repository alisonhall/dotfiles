#!/bin/sh
# Save all of the git field names as a variable to be used in --format options
# chmod +x format-git-objects.sh

export allFormatOptions='
___________________________________________________________
HEAD                            | %(HEAD)
worktreepath                    | %(worktreepath)
refname (r)                     | %(refname)
    refname:short               | %(refname:short)
    refname:lstrip=2            | %(refname:lstrip=2)
    refname:rstrip=2            | %(refname:rstrip=2)
    refname:track               | %(refname:short)
symref                          | %(symref)
version:refname                 | !(version:refname)
deltabase                       | %(deltabase)
upstream                        | %(upstream)
    upstream:short              | %(upstream:short)
    upstream:lstrip=2           | %(upstream:lstrip=2)
    upstream:rstrip=2           | %(upstream:rstrip=2)
    upstream:track              | %(upstream:track)
    upstream:trackshort         | %(upstream:trackshort)
    upstream:remotename         | %(upstream:remotename)
    upstream:remoteref          | %(upstream:remoteref)
push                            | %(push)
    push:short                  | %(push:short)
    push:lstrip=2               | %(push:lstrip=2)
    push:rstrip=2               | %(push:rstrip=2)
    push:track                  | %(push:track)
    push:trackshort             | %(push:trackshort)
    push:remotename             | %(push:remotename)
    push:remoteref              | %(push:remoteref)
tree                            | %(tree)
    tree:short                  | %(tree:short)
    tree:short=3                | %(tree:short=3)
parent                          | %(parent)
object                          | %(object)
    objecttype (t)              | %(objecttype)
    objectsize                  | %(objectsize)
    objectname (o)              | %(objectname)
    objectname:short            | %(objectname:short)
    objectname:short=3          | %(objectname:short=3)
type                            | %(type)
tag                             | %(tag)
creator                         | %(creator)
    creatordate                 | %(creatordate)
    creatordate:relative        | %(creatordate:relative)
author                          | %(author)
    authorname (n)              | %(authorname)
    authoremail (e)             | %(authoremail)
    authoremail:trim            | %(authoremail:trim)
    authoremail:localpart       | %(authoremail:localpart)
    authordate (d)              | %(authordate)
    authordate:relative         | %(authordate:relative)
committer                       | %(committer)
    committername (cn)          | %(committername)
    committeremail              | %(committeremail)
    committeremail:trim         | %(committeremail:trim)
    committeremail:localpart    | %(committeremail:localpart)
    committerdate (cd)          | %(committerdate)
    commiteerdate:relative      | %(committerdate:relative)
tagger                          | %(tagger)
    taggername                  | %(taggername)
    taggeremail                 | %(taggeremail)
    taggeremail:trim            | %(taggeremail:trim)
    taggeremail:localpart       | %(taggeremail:localpart)
    taggerdate                  | %(taggerdate)
    taggerdate:relative         | %(taggerdate:relative)
contents -------> %(color:dim)
%(contents)
%(color:reset)<-------
    contents:size               | %(contents:size)
    contents:signature          | %(contents:signature)
    contents:subject            | %(contents:subject)
    subject (s)                 | %(subject)
    subject:sanitize            | %(subject:sanitize)
    contents:body -------> %(color:dim)
%(contents:body)
%(color:reset)<-------
body (b)-------> %(color:dim)
%(body)
%(color:reset)<-------
contents:lines=3 -------> %(color:dim)
%(contents:lines=3)
%(color:reset)<-------
color:red                       | %(color:red)example
color:blue                      | %(color:blue)example
color:green                     | %(color:green)example
color:yellow                    | %(color:yellow)example
color:magenta                   | %(color:magenta)example
color:cyan                      | %(color:cyan)example
color:reset                     | %(color:reset)example
-----------------------------------------------------------
';

# eval=`git for-each-ref --shell --format="$fmt" \
# 	--sort='*objecttype' \
# 	--sort=-taggerdate \
# 	refs/tags`
# eval "$eval"

#git for-each-ref --format="%(if)%(HEAD)%(then)* %(else)  %(end)%(refname:short)" refs/heads/

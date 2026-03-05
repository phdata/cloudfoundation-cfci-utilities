filename="stacks"
while read -r deploy_stack
do
    depends=$(jq -r '.depends' <<< "$deploy_stack")
    echo "$depends"
done < $filename

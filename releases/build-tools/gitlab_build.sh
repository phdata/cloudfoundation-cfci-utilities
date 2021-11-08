#!/bin/bash 

#  Copyright 2018 phData Inc.
# 
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
# 
#  http://www.apache.org/licenses/LICENSE-2.0
# 
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.


#shell options 
set -e
if [ "${trace-}" = "true" ]; then 
  set -x
fi

# variables/ labels
prefix="phData-CFCI build:"
nl_sep=" <br> "
# head_branch=`echo "${CODEBUILD_WEBHOOK_HEAD_REF#*heads/}"`  #branch name through which the PR is created
more_details=" $nl_sep $nl_sep BUILD Log:  $nl_sep "$CI_JOB_URL
build_failed="BUILD FAILED. Review the below log:   $nl_sep "
repo_path=$(basename "$(dirname "$CI_PROJECT_DIR")")/$(basename "$CI_PROJECT_DIR")
repo_home=$(basename "$CI_PROJECT_DIR")
summary_label="DEPLOY PLAN for environment:"
rc_label="Stack is in ROLLBACK_COMPLETE state. CFCI will DELETE this stack and try to RECREATE it"
multi_env_label="Multiple deploy environments are defined in your deployment descriptor.  $nl_sep Cloudfoundation will deploy stacks in all defined enviroments, change the stack level deploy_env attribute to include OR skip an environment."
touch output stack_log tmp_output ignore deploy undeploy
sep_line="=================="
sep_line_single="------------"
ran=$RANDOM
descriptor_blocks=( "deploy" "undeploy" "ignore" )
# printenv
artifactory_base_url=https://repository.phdata.io/artifactory/cf-gold-templates/
download=true
no_changeset=false
pipelinename=`echo $CODEBUILD_INITIATOR | cut -d'/' -f2-`
codepipeline_base_url="https://console.aws.amazon.com/codesuite/codepipeline/pipelines/$pipelinename/view?region=$AWS_DEFAULT_REGION"
more_details_with_appr=" $nl_sep  $nl_sep Use the below link to approve the DEPLOY operation for this environment:  $nl_sep $CI_PIPELINE_URL $nl_sep $nl_sep BUILD Log:  $nl_sep "$CI_JOB_URL
note_summary="This note contains:"
plan_all_note="As the plan_all attribute is set to true in buildspec file, DEPLOY PLAN is generated for all defined environments"
repository_base_url="${repository_base_url/TOKEN/$cloudsmith_entitlement_token}"
repository_base_url="$repository_base_url/$cloudsmith_repository_name/raw/versions"
# validate deployment descriptor
validate_deployment_descriptor() {
    # look for parse errors
    if grep -q "while parsing " parse_log ; then
        echo "ERROR while parsing the deployment descriptor:" >> output
        cat parse_log >> output
        exit 0
    fi
    #check if attributes are specified using = instead of colon
    for block in "${descriptor_blocks[@]}"
    do
        rm -f "$block"_tmp
        while read -r deploy_stack
        do
           if [[ "$deploy_stack" == *": null"* ]]; then
                echo "" >> descriptor_errors
                echo "**$block:${deploy_stack//: null/}**" >> descriptor_errors
                echo "ERROR: stack specification error, cannot use "=" while specifying attributes, use colon(:) instead." >> descriptor_errors
           fi
        done < $block
    done

    #duplicate code - move to a function later
    if [ -s descriptor_errors ] ; then
        echo "Build has identified below issues with deployment descriptor, please review and fix." >> output
        # echo "" >> output
        cat descriptor_errors >> output
        exit_and_set_build_status
     fi

    no_ext_stack=false
    stack_not_exist=false
    for block in "${descriptor_blocks[@]}"
    do
        while read -r deploy_stack
        do
            #check if deploy_env contains current env OR all
            check_if_deploy_requested

            stack_name_with_ext=$(jq -r '.name' <<< "$deploy_stack")
            gold=$(jq -r '.phdata_gold_template' <<< "$deploy_stack")
            gold=`echo "$gold" | tr '[:upper:]' '[:lower:]'`  #switch to lower case
            template_version=$(jq -r '.version' <<< "$deploy_stack")
            block_printed=false
             if [ "$stack_name_with_ext" = null ] || [ "${stack_name_with_ext##*.}" != "yaml" ]; then
                no_ext_stack=true
                if [ "$block_printed" = false ];then
                    block_printed=true
                    echo "" >> descriptor_errors
                    echo "**$block:$deploy_stack**" >> descriptor_errors
                fi
                echo "ERROR: stackname along with extension(yaml) must be specified in the deployment descriptor." >> descriptor_errors
                continue
            fi
            
            echo ":$stack_name_with_ext" >> "$block"_tmp

            if [[ $block == "deploy" ]];then
                no_ext_stack=false
                block_printed=false
                # echo $stack_name_with_ext >> "$block"_tmp
                # check if name, phdata_gold_template and version attributes are set correctly  
                if [ "$gold" = null ] ; then
                    if [ "$block_printed" = false ];then
                        block_printed=true
                        echo "" >> descriptor_errors
                        echo "**$block:$deploy_stack**" >> descriptor_errors
                    fi
                    echo "ERROR: phdata_gold_template must be specified while describing the stack under DEPLOY" >> descriptor_errors
                    continue
                fi

                if [ "$gold" = true ] && [ "$template_version" = null ] ; then
                    if [ "$block_printed" = false ];then
                        block_printed=true
                        echo "" >> descriptor_errors
                        echo "**$block:$deploy_stack**" >> descriptor_errors
                    fi
                    echo "ERROR:gold template version must be specified when phdata_gold_template is set to true" >> descriptor_errors
                fi

                if [ "$env_status" -eq 0 ]  || [ "$all_status" -eq 0 ]; then
                    #code to check if statck exist OR throw an error
                    if [ ! -f "config/$env/$stack_name_with_ext" ]; then
                        stack_not_exist=true
                        if [ "$block_printed" = false ];then
                                    block_printed=true
                                    echo "" >> descriptor_errors
                                    echo "**$block:$deploy_stack**" >> descriptor_errors
                        fi
                        echo "ERROR: stack file :$stack_name_with_ext specified in the deployment descriptor doesn't exist." >> descriptor_errors
                        continue
                    fi

                    if [ "$gold" != true ]; then
                            template_path_string=`grep "template_path" config/$env/$stack_name_with_ext | head -1`
                            #template_path value from stack file
                            template_path=`echo $template_path_string | cut -d':' -f2-`
                            # remove line comment at the end and trim template path
                            template_path=`echo ${template_path%#*} | sed -e 's/^[[:space:]]*//'`
                            if [ ! -f "templates/$template_path" ]; then
                                if [ "$block_printed" = false ];then
                                    block_printed=true
                                    echo "" >> descriptor_errors
                                    echo "**$block:$deploy_stack**" >> descriptor_errors
                                fi
                                echo "ERROR: Local template path:$template_path specified in the stack:$stack_name_with_ext doesn't exist." >> descriptor_errors
                            fi
                    fi
                fi

            elif [ "$env_status" -eq 0 ]  || [ "$all_status" -eq 0 ]; then
                #same code in 2 places - move to a funtion later
                #code to check if statck exist OR throw an error
                if [ ! -f "config/$env/$stack_name_with_ext" ]; then
                    stack_not_exist=true
                    if [ "$block_printed" = false ];then
                                block_printed=true
                                echo "" >> descriptor_errors
                                echo "**$block:$deploy_stack**" >> descriptor_errors
                    fi
                    echo "ERROR: stack file :$stack_name_with_ext specified in the deployment descriptor doesn't exist." >> descriptor_errors
                fi
            fi
        done < $block
    done

    # if errors exist in deployment descriptor do not download gold template - (save build minutes)
    if [ -s descriptor_errors ] ; then
         if [ "$stack_not_exist" = true ]; then
            echo "Build has identified below issues with deployment descriptor, please review and fix." >> output
            # echo "" >> output
            cat descriptor_errors >> output
            exit_and_set_build_status
         fi
        download=false
    else
        download=true
    fi

    for block in "${descriptor_blocks[@]}"
    do
        while read -r deploy_stack
        do
            check_if_deploy_requested
            no_ext_stack=false
            stack_name_with_ext=$(jq -r '.name' <<< "$deploy_stack")
            gold=$(jq -r '.phdata_gold_template' <<< "$deploy_stack")
            gold=`echo "$gold" | tr '[:upper:]' '[:lower:]'`  #switch to lower case
            template_version=$(jq -r '.version' <<< "$deploy_stack")
            depends_file=$(jq -r '.depends' <<< "$deploy_stack")
            SAM_build=$(jq -r '.SAM_build' <<< "$deploy_stack")

            if [ "$stack_name_with_ext" = null ] || [ "$gold" = null ] ; then
                continue
            fi

            if [[ "${stack_name_with_ext##*.}" != "yaml" ]]; then
                no_ext_stack=true
            fi
            #check if stack listed in multiple blocks
            for sub_block in "${descriptor_blocks[@]}"
            do
                if [ "$sub_block" == "$block" ]; then
                    continue
                else    
                    if grep ":$stack_name_with_ext" "$sub_block"_tmp ; then
                        if [ ! -f "descriptor_errors" ]; then
                            touch descriptor_errors
                        fi
                        if ! grep  "$stack_name_with_ext is listed in block" descriptor_errors ; then
                             echo "" >> descriptor_errors
                            echo "**$block:$deploy_stack**" >> descriptor_errors
                            echo "ERROR: Same stack cannot be specified under multiple blocks(${descriptor_blocks[@]}) in deployment descriptor." >> descriptor_errors
                            echo "$stack_name_with_ext is listed in block:$block and block:$sub_block" >> descriptor_errors
                            download=false
                        fi
                    fi  
                fi
            done
        
            if [[ $block == "deploy" ]] && [ "$no_ext_stack" = false ] ; then
                block_printed=false

                #check if same file is specified more than once under deploy
                stack_count=`grep -o ":$stack_name_with_ext" deploy_tmp | wc -l`
                if (( $stack_count > 1 )); then
                    if ! grep  "ERROR:Stack $stack_name_with_ext is listed more than once" descriptor_errors ; then
                    echo "" >> descriptor_errors
                    echo "**$block:$deploy_stack**" >> descriptor_errors
                    echo "ERROR:Stack $stack_name_with_ext is listed more than once in deployment descriptor." >> descriptor_errors
                    fi
                fi

                if [ "$env_status" -eq 0 ]  || [ "$all_status" -eq 0 ]; then
                    # check if dependent stacks are listed for a stack
                    cd ..
                    current_stack="${stack_name_with_ext}"
                    python graph.py $project $env "$env/${stack_name_with_ext%.*}"
                    cat stack_graph
                    cp stack_graph $project
                    cd $project
                    while read -r dep_stack
                    do
                        if ! grep -q ":$dep_stack" deploy_tmp ; then
                            no_changeset=true
                            get_stack_action $env/${dep_stack%.*} $block
                            no_changeset=false
                            if [[ $stack_action = "A" ]]; then
                                if [ "$block_printed" = false ];then
                                    block_printed=true
                                    echo "" >> descriptor_errors
                                    echo "**$block:$deploy_stack**" >> descriptor_errors
                                fi
                            echo "ERROR:Stack $current_stack has a dependent stack: $dep_stack, which is not listed in deployment descriptor." >> descriptor_errors
                            fi
                        else
                            # check if dependent stacks is listed after the stack
                            # stack_line=$(awk '/$stack_name_with_ext/{ print NR; exit }' deploy_tmp)
                            stack_line=`grep -n ":$stack_name_with_ext" deploy_tmp | cut -d : -f 1`
                            # dep_stack_line=$(awk '/$dep_stack/{ print NR; exit }' deploy_tmp)
                            dep_stack_line=`grep -n ":$dep_stack" deploy_tmp | cut -d : -f 1`
                            if (( $dep_stack_line > $stack_line )); then
                                if [ "$block_printed" = false ];then
                                block_printed=true
                                echo "" >> descriptor_errors
                                echo "**$block:$deploy_stack**" >> descriptor_errors
                                fi
                            echo "ERROR:Stack $current_stack has a dependent stack: $dep_stack, which is listed after $stack_name_with_ext in the deployment descriptor." >> descriptor_errors
                            # echo "" >> descriptor_errors
                            fi
                        fi
                    done < stack_graph

                    stack_name_with_ext=$current_stack
                    # check and download gold template
                    if [ "$gold" = true ] && [ "$template_version" != null ] && [ "$no_ext_stack" = false ] ; then
                            download_artifactory_template $stack_name_with_ext
                            if [ "$template_exist" = false ];then
                                echo "" >> descriptor_errors
                                echo "**$block:$deploy_stack**" >> descriptor_errors
                                echo "ERROR:Requested gold template version doesn't exist, update the template version in deployment descriptor." >> descriptor_errors
                                download=false
                            fi
                    fi

                    # check and download depends file
                    if [ "$depends_file" != null ]; then
                        IFS='/ ' read -r -a array <<< "$depends_file"
                        depends_file_name="${array[1]}"
                        depends_file_version="${array[2]%.*}"
                        depends_file_ext="${array[2]##*.}"  #just extension
                        depends_artfct_uri=$repository_base_url/$depends_file_version/$depends_file_name.$depends_file_ext
                        if is_package_available $depends_file_name.$depends_file_ext $depends_file_version; then
                            if [[ "$CODEBUILD_INITIATOR" == "codepipeline/"* ]]; then
                                # depends_dir=$(echo $depends_file | sed 's|^[^/]*\(/[^/]*/\).*$|\1|')  # get string between two slashes
                                depends_dir=`basename $(dirname "${depends_file}")`  # relative path of zipfile
                                depends_file_name=${depends_file##*/}
                                lambda_src_bucket=$(yq -r  .template_bucket_name config/$env/config.yaml)
                                switch_set_e
                                aws s3api head-object --bucket $lambda_src_bucket --key $depends_file
                                if [[ $? -ne 0 ]]; then
                                    mkdir -p $depends_dir
                                    cd $depends_dir && { curl -O $depends_artfct_uri ; cd -; }
                                    aws s3 cp $depends_dir/$depends_file_name s3://$lambda_src_bucket/$depends_file
                                    if [ $? = 0 ]; then
                                        echo "s3://$lambda_src_bucket/$depends_file  upload is successful"
                                    else
                                        echo "ERROR while uploading dependency file: $depends_file to bucket:$lambda_src_bucket" >> descriptor_errors
                                    fi
                                else
                                    echo "WARN: Requested depends file:$depends_file already exist in the bucket $lambda_src_bucket"
                                fi
                                switch_set_e
                            fi
                        else
                            echo "ERROR:Requested dependency file: $depends_file doesnt exist in phData repository." >> descriptor_errors
                        fi
                    fi

                    # process sam package
                    if [[ "$SAM_build" != null && "$SAM_build" = true ]]; then
                        sam_template_filepath=$(yq -r  .template_path config/$env/$stack_name_with_ext)
                        sam_template_name=`basename $sam_template_filepath`
                        sam_app_path=$(dirname "${sam_template_filepath}")
                        lambda_src_bucket=$(yq -r  .template_bucket_name config/$env/config.yaml)
                        appname=`basename $sam_app_path`
                        cd templates/$sam_app_path
                        # FIX Me: uploads the lambda source to cloudfoundation bucket during the PLAN. 
                        # Find a way to get the zip file name before upload OR delete the file after PLAN is generated and DEPLOY is completed through sceptre commands.
                        switch_set_e
                        sam build &> build_output 
                        if grep -q "Build Failed" build_output ; then
                            echo "ERROR while executing the build for application $application_directory" >> descriptor_errors
                            cat build_output  >> descriptor_errors
                        fi
                        sam package --s3-bucket $lambda_src_bucket --s3-prefix "lambda/$appname" --output-template-file "generated_$sam_template_name.yaml" &> pack_output
                        switch_set_e
                        if grep -q "Error" pack_output ; then
                            echo "ERROR:: While building SAM package, refer to the below log" >> descriptor_errors
                            cat pack_output >>  $CODEBUILD_SRC_DIR/final_output
                            exit_and_set_build_status
                        else
                            mv $sam_template_name "original-$sam_template_name"
                            mv "generated_$sam_template_name.yaml" $sam_template_name
                            cd -
                        fi
                    fi

                fi
            fi

        done < $block
    done

    if [ -s descriptor_errors ] ; then
        echo "Build has identified below issues with deployment descriptor, please review and fix." >> output
        echo "" >> output
        cat descriptor_errors >> output
        exit_and_set_build_status
     fi
}

pull_templates() {
    # code to pull all templates first after descriptor validation
    # Then run sceptre status? # not manadtory as 
    echo "dummy method for now"
}

# check if template exist in artifactory. status 200 is true. else false
is_package_available () {
    package_output=$(cloudsmith list packages phdata/$cloudsmith_repository_name -q "name:$1 AND version:$2")
    echo "$package_output"
    if [[ $package_output == *"0 packages visible"* ]]; then
        echo "Package not found"
        return 1 # 1 = false
    else
        echo "package available to download"
        return 0 # 0 = true
    fi
}

# check if template exist in artifactory. status 200 is true. else false
check_template_exist() {
    url=$1
    if [ "$quickstart" = true ]; then
        check_url=$(curl -s -o /dev/null -w "%{http_code}" ${url})
    else
        check_url=$(curl -u$artifactory_usr:$artifactory_pwd -s -o /dev/null -w "%{http_code}" ${url})
    fi
    echo "http_code:$check_url"
    case $check_url in
    [200]*)
      # 0 = true
      return 0
      ;;
    [404]*)
      # 1 = false
      return 1
      ;;
    *)
      echo "URL error - HTTP error code $check_url: $url"
      exit 0
    ;;
    esac
}

download_artifactory_template() {
    template_exist=""
    #template path from stack file
    template_path_string=`grep "template_path" config/$env/$1 | head -1`
    #template_path value from stack file
    template_path=`echo $template_path_string | cut -d':' -f2-`
    # remove line comment at the end and trim template path
    template_path=`echo ${template_path%#*} | sed -e 's/^[[:space:]]*//'`
    # if [[ "$template_name" == *\/* ]] ; then  #contains slash / in sub dir
    artfct_template_path="${template_path%.*}" #removes extension
    artfct_template_ext="${template_path##*.}"  #just extension
    artfct_template_name=`echo "$artfct_template_path" | sed 's:.*/::'` #stack name without path
    # artfct_uri=$repository_base_url$artfct_template_path/$artfct_template_name-$template_version.$artfct_template_ext
    artfct_uri=$repository_base_url/$template_version/$artfct_template_name.$artfct_template_ext
    echo $artfct_uri
    if is_package_available $artfct_template_name.$artfct_template_ext $template_version ; then
        template_exist=true
        if [ "$download" = true ];then
            echo "Downloading: $artfct_uri"
            echo "using phData-gold-template: $artfct_uri"  > artf
            curl -O $artfct_uri
            if [[ "$template_path" == *\/* ]] ; then
                template_dir="$CODEBUILD_SRC_DIR/$project/templates/${artfct_template_path%/*}"
                echo "template_dir :: $template_dir"
            else
                template_dir="$CODEBUILD_SRC_DIR/$project/templates"
                echo "template-dir :: $template_dir"
            fi
        # mkdir -p $CODEBUILD_${artfct_template_path%/*}
            mkdir -p $template_dir
            cp $artfct_template_name.$artfct_template_ext $template_dir/$artfct_template_name.$artfct_template_ext
        fi
        # ls -lhrt
    else
        template_exist=false
    fi
}

check_if_deploy_requested () {
# check if current environment exist in deploy_env
switch_set_e
env_result=$(jq -r --exit-status --arg env "$env" 'select(.deploy_env | index($env))' <<< "$deploy_stack")
env_status=$?

# check if all exist in deploy_env
all_result=$(jq -r --exit-status 'select(.deploy_env | index("all"))' <<< "$deploy_stack")
all_status=$?
switch_set_e

}

#called to generate deployment summary before actual DEPLOY
function cfci_plan (){
    rm -f A_output M_output D_output O_output utd_output output
    touch A_output M_output D_output O_output utd_output output

    for block in "${descriptor_blocks[@]}"
    do
        while read -r deploy_stack
        do  
            echo "$deploy_stack"
            stack_name_with_ext=$(jq -r '.name' <<< "$deploy_stack")
            stack="${stack_name_with_ext%.*}" #remove extenstion - for stack
            
            #check if deploy_env contains current env OR all
            check_if_deploy_requested

            if [[ $block == "ignore" ]]; then
                stack_action="IGN"
            elif [ "$env_status" -eq 0 ]  || [ "$all_status" -eq 0 ]; then
                get_stack_action $env/$stack $block
            else
                stack_action="env_IGN"
            fi

            case $stack_action in
            A)
                echo "$sep_line_single STACK:$stack_name_with_ext $sep_line_single" >> A_output
                if [[ $stack_status == "\"ROLLBACK_COMPLETE\"" ]]; then
                    echo $rc_label >> A_output
                fi
                switch_set_e
                sceptre --ignore-dependencies generate $stack_name_with_ext &> output
                switch_set_e
                if grep "Traceback " output ; then
                    echo "An error occured while executing generate-stack for $stack_name_with_ext, refer to below message: $nl_sep " >> A_output
                elif grep "An error occured writing the JSON object" output ; then
                    echo "An error occured while executing generate-stack for $stack_name_with_ext, refer to below message: $nl_sep " >> A_output
                    echo "This is possibly due to formatting issue/additional spaces in your template." >> A_output
                # else   # DO NOT DELETE the BELOW BLOCK - need to revisit
                #     switch_set_e
                #     jq 'del(.[].Outputs,.[].Parameters)' output >> A_output
                # this fails if json format is not good or jas a line like this
                # /Users/source/wolkaws-valhalla/valhalla/templates/general_cluster.py:153: DeprecationWarning: invalid escape sequence \d
                #   AllowedPattern="(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})",
                #     switch_set_e
                fi
                cat output >> A_output
                ;;
            M)
                echo "$sep_line_single STACK:$stack_name_with_ext $sep_line_single" >> M_output
                if [ "$traceback" = true ];then
                    echo "Error while creating changeset for $stack_name_with_ext, Refer to the message below:" >> M_output
                    cat cs_output >> M_output
                elif [ "$status" == "Traceback" ] || [ "$status" == "error" ] ; then
                    echo "Error occurred while describing the changeset, Review the log below:" >> M_output 
                    cat output >> M_output
                elif [ "$status" == "nochangeset" ]; then
                    echo "Error occurred while creating the changeset, Review the log below:" >> M_output
                    cat cs_output >> M_output
                else
                    # cat output >> M_output
                    jq 'del(.ResponseMetadata,.CreationTime,.StackId,.ChangeSetId,.ChangeSetName)' output >> M_output
                    changeset_action "delete" "$stack_name_with_ext" "$changeset_name" #delete change-set
                fi
                
                ;;
            utd) 
                echo "$stack_name_with_ext ---- Infrastructure is up-to-date." >> utd_output
                changeset_action "delete" "$stack_name_with_ext" "$changeset_name" #delete change-set
                ;;
            D | ND) 
                # echo "$sep_line_single STACK:$stack_name_with_ext $sep_line_single" >> D_output
                
                if [[ $stack_action == "ND" ]]; then
                    echo "$stack_name_with_ext ---- IGNORED: Undeploy requested, but stack is not deployed" >> O_output
                else
                    echo "$sep_line_single STACK:$stack_name_with_ext $sep_line_single" >> D_output
                    echo "$stack_name_with_ext ---- Stack and the dependent stacks will be deleted if they exist." >> D_output
                    switch_set_e
                    # sceptre generate $stack_name_with_ext &> output
                    # sceptre --ignore-dependencies generate $stack_name_with_ext &> output
                    echo "N" | sceptre delete $stack_name_with_ext &> tmp_output
                    switch_set_e
                    sed \$d tmp_output > output
                    if grep "Traceback " output ; then
                        echo "An error occured while executing generate-stack for $stack_name_with_ext, refer to below message: $nl_sep " >> D_output
                    # else 
                    #     jq 'del(.[].Outputs,.[].Parameters)' output >> D_output
                    fi
                cat output >> D_output
                fi
                ;;
            IGN | env_IGN) 
                if [[ $stack_action == "env_IGN" ]]; then
                    echo "$stack_name_with_ext ---- IGNORED, Deploy not requested for environment: $env " >> O_output
                else
                    echo "$stack_name_with_ext ---- IGNORED:No action will be performed by build" >> O_output
                fi
                ;;
            *) 
                echo "$stack_name_with_ext ---- No action will be performed by build" >> O_output
                ;;
            esac

        done < $block
    done

    plan_comment="$summary_label $env_name"

    if [ -s utd_output ]; then
        format_change_output utd_output
        plan_comment="$plan_comment $nl_sep $nl_sep $sep_line STACKS - Infrastructure up-to-date $sep_line $nl_sep $stack_changes"
    fi

    if [ -s A_output ]; then
        format_change_output A_output
        plan_comment="$plan_comment $nl_sep  $nl_sep $sep_line STACKS - DEPLOY REQUESTED $sep_line $nl_sep $stack_changes"
    fi

    if [ -s M_output ]; then
        format_change_output M_output
        plan_comment="$plan_comment $nl_sep $nl_sep $sep_line CHANGESET FOR MODIFIED STACKS $sep_line $nl_sep $stack_changes"
    fi

    if [ -s D_output ]; then
        format_change_output D_output
        plan_comment="$plan_comment $nl_sep $nl_sep $sep_line STACKS - UNDEPLOY REQUESTED $sep_line $nl_sep  $stack_changes"
    fi

    if [ -s template_NF ]; then
        tnf_text="Requested gold template version doesn't exist for below stacks, OR the version is not specified."
        echo -e "$tnf_text\n\n$(cat template_NF)" > template_NF
        format_change_output template_NF
        plan_comment="$plan_comment $nl_sep $nl_sep $sep_line STACKS - TEMPLATE NOT FOUND $sep_line $nl_sep $stack_changes"
    fi

    if [ -s O_output ] || [ -s ignored_output ] ; then
        if [ -s O_output ] ; then
        format_change_output O_output
        plan_comment="$plan_comment $nl_sep $nl_sep $sep_line STACKS - NO ACTION REQUIRED $sep_line $nl_sep  $stack_changes"
        fi
        if [ -s ignored_output ] ; then
        format_change_output ignored_output
        plan_comment="$plan_comment $nl_sep $stack_changes"
        fi
    fi

    if [ -s template_NF ] || [ -s D_output ]  || [ -s M_output ] || [ -s A_output ] || [ -s ignored_output ] ; then
        echo "Identified changes for stacks"
    else
        plan_comment="No STACKS were modified in current request for Environment:$env_name. No action will be performed by the BUILD when this change is deployed. $nl_sep Make sure that all stacks are be defined in deployment descriptor(deployment.yaml) and deploy_env is specified."
    fi
}

#called to DEPLOY stacks
function cfci_deploy (){
    rm -f stack_log output upd_stack_log o_stack_log
    touch stack_log output upd_stack_log o_stack_log
    # git checkout master # switch to master
    # git diff --name-status "HEAD^" "HEAD" '*.yaml' | grep -v 'templates/' | tee git_delta
    for block in "${descriptor_blocks[@]}"
    do
        while read -r deploy_stack
        do
        stack_name_with_ext=$(jq -r '.name' <<< "$deploy_stack")
        # stack=`echo $deploy_stack | awk -F ".yaml-" '{ print $1 }'`
        stack="${stack_name_with_ext%.*}" #remove extenstion - needed when template version is not specified in the descriptor
        # template_version=`echo $deploy_stack | awk -F ".yaml-" '{ print $2 }'`
        # stack_name_with_ext="$stack.yaml"
        # cd ..
        # python graph_$cfci_version.py $project $env "$stack"
        # cat stack_graph
        
        # cp stack_graph $project
        # cd $project

        # check if current environment exist in deploy_env
        switch_set_e
        env_result=$(jq -r --exit-status --arg env "$env" 'select(.deploy_env | index($env))' <<< "$deploy_stack")
        env_status=$?

        # check if current environment exist in deploy_env
        all_result=$(jq -r --exit-status 'select(.deploy_env | index("all"))' <<< "$deploy_stack")
        all_status=$?
        switch_set_e

        if [[ $block == "ignore" ]]; then
            stack_action="IGN"                
        elif [ "$env_status" -eq 0 ]  || [ "$all_status" -eq 0 ]; then
            get_stack_action $env/$stack $block
        else
            stack_action="env_IGN"  
        fi

        case $stack_action in
            A)
                echo "$sep_line_single CREATE_STACK for $stack_name_with_ext $sep_line_single" >> stack_log
                : > output
                if [[ $stack_status == "\"ROLLBACK_COMPLETE\"" ]]; then
                    echo $rc_label > output
                    switch_set_e
                    sceptre --no-colour delete -y "$stack_name_with_ext" &>> output
                    switch_set_e
                fi
                if grep "Traceback " output ; then
                    echo "An error occured while deleting stack $stack_to_run.yaml, refer to below message: $nl_sep " >> stack_log
                    cat output >> stack_log
                else
                    switch_set_e
                    sceptre --no-colour create -y "$stack_name_with_ext" &>> output
                    switch_set_e
                fi
                
                if grep "Traceback " output ; then
                    echo "An error occured while executing stack $stack_to_run.yaml, refer to below message: $nl_sep " >> stack_log
                fi
                cat output >> stack_log
                ;;
            M)
                echo "$sep_line_single UPDATE_STACK for $stack_name_with_ext $sep_line_single" >> stack_log
                if [ "$traceback" = true ];then
                    echo "Error while creating changeset for $stack_name_with_ext, Refer to the message below:" >> stack_log
                    cat cs_output >> stack_log
                elif [ "$status" == "Traceback" ] || [ "$status" == "error" ] ; then
                    echo "Error occurred while describing the changeset, Review the log below:" >> stack_log
                    cat output >> stack_log
                elif [ "$status" == "nochangeset" ]; then
                    echo "Error occurred while creating the changeset, Review the log below:" >> stack_log
                    cat cs_output >> stack_log
                    cat output >> stack_log
                else 
                    switch_set_e
                    sceptre --no-colour --ignore-dependencies execute -y "$stack_name_with_ext" "$changeset_name" &> output
                    switch_set_e
                    cat output >> stack_log
                fi
                changeset_action "delete" "$stack_name_with_ext" "$changeset_name" #delete change-set
                ;;
            utd)
                echo "$stack_name_with_ext ---- No changes, Infrastructure is up-to-date." >> upd_stack_log
                changeset_action "delete" "$stack_name_with_ext" "$changeset_name" #delete change-set
                ;;
            D | ND)
                : > output
                # echo "$stack_name_with_ext ---- Stack file will be deleted." >> stack_log
                if [[ $stack_action == "ND" ]]; then
                    echo "$stack_name_with_ext ---- IGNORED: Undeploy requested, but stack is not deployed" >> o_stack_log
                else
                    echo "$sep_line_single DELETE_STACK for $stack_name_with_ext $sep_line_single" >> stack_log
                    sceptre --no-colour delete -y "$stack_name_with_ext" &> output
                    if grep "Traceback " output ; then
                        echo "An error occured while deleting stack $stack_to_run.yaml, refer to below message: $nl_sep " >> stack_log
                    fi
                    cat output >> stack_log
                fi
                ;;
            IGN | env_IGN) 
                if [[ $stack_action == "env_IGN" ]]; then
                    echo "$stack_name_with_ext ---- IGNORED, Deploy not requested for environment: $env " >> o_stack_log
                else
                    echo "$stack_name_with_ext ---- IGNORED:No action performed by build" >> o_stack_log
                fi
                ;;
            *) 
                echo "$stack_name_with_ext ---- No action performed by build" >> o_stack_log
                ;;
        esac
        # done < stack_graph
        done < $block
    done

    if [ -s stack_log ]; then
        deploy_comment="DEPLOY OPERATION COMPLETED for environment: $env_name, Review the below log for any errors:"
        if [ -s upd_stack_log ] || [ -s o_stack_log ]; then
            echo "$sep_line_single STACKS - NO ACTION PERFORMED $sep_line_single" >> stack_log
            cat upd_stack_log >> stack_log
            cat o_stack_log >> stack_log
        fi
    elif [ -s upd_stack_log ] || [ -s o_stack_log ]; then
        deploy_comment="DEPLOY OPERATION COMPLETED for environment: $env_name, No action performed"
        echo "$sep_line_single STACKS - NO ACTION PERFORMED $sep_line_single" >> stack_log
        cat upd_stack_log >> stack_log
        cat o_stack_log >> stack_log
    else
        deploy_comment="No changes,Infrastructure is up-to-date. No action was performed by CFCI BUILD."
    fi
}

write_comments_file () {
    for param in "$@"
    do
        echo "$param" >> comments_file
    done
}

get_stack_action () {
    stack_status=$(jq --arg stack "$1" -c '.[$stack]' stack_status_report)
    traceback=false
    stack_name_rem_slash=`sed -e 's#.*/\(\)#\1#' <<< "$1"`
    stack_name_with_ext="$1.yaml"
    changeset_name="${stack_name_rem_slash%.*}$ran"
    # if [[ "$2" == "ignore" ]]; then
    #     stack_action="IGN"
    # else
    case $stack_status in
    "\"PENDING\"" | "\"ROLLBACK_COMPLETE\"")
        if [[ "$2" == "deploy" ]]; then
            stack_action="A"
        # elif [[ "$2" == "ignore" ]]; then
        #     stack_action="IGN"
        elif [[ "$2" == "undeploy" ]]; then
            stack_action="ND" #not deployed
        fi
        ;;
    "\"CREATE_COMPLETE\"" | "\"UPDATE_COMPLETE\"" | "\"UPDATE_ROLLBACK_COMPLETE\"" )
        if [[ "$2" == "deploy" ]]; then
            stack_action="M"
            if [ "$no_changeset" = false ] ; then
                switch_set_e
                sceptre --no-colour create -y $stack_name_with_ext "$changeset_name" &> cs_output
                switch_set_e
                if grep "Traceback " cs_output ; then
                        traceback=true
                else
                    changeset_action "describe" "$stack_name_with_ext" "$changeset_name"
                    if [[ $status == "FAILED" ]]; then
                        StatusReason=$(jq -r ".StatusReason" output)
                        if [[ $StatusReason == *"t contain changes. Submit different information"* || $StatusReason == "No updates are to be performed."* ]]; then
                            echo "Infrastructure is up-to-date for $1"
                            stack_action="utd" #up to date
                        fi
                    fi
                fi
            fi
        elif [[ "$2" == "undeploy" ]]; then
            stack_action="D"
        fi
        ;;
    *)
        echo "NO action"
        ;;
    esac
}

changeset_action() {
    i=0
    while true ;
    do
        switch_set_e
        if [ "$1" = "describe" ]; then
            sceptre --no-colour --output json --ignore-dependencies describe change-set -v $2 $3 &> output
        elif [ "$1" = "delete" ]; then
            sceptre --no-colour --output json describe change-set $2 $3 &> output
        fi
        switch_set_e
        if grep "Traceback " output ; then
            status="Traceback"
        elif grep "ChangeSet.* does not exist" output ; then
            status="nochangeset"
        elif grep "An error occurred" output ; then
            status="error"
        else 
            status=$(jq -r ".Status" output)
        fi
        echo "status is::$status"
        case $status in
        *"CREATE_IN_PROGRESS"*)
            sleep 3
            let i+=3
            echo "CREATE_IN_PROGRESS"
            if [ $i -ge 300 ];then break 
            fi
            ;;
        *"Traceback"* | *"error"*)
            echo "Error occurred while describing changeset"
            break
            ;;
        *"nochangeset"*)
            echo "ChangeSet does not exist"
            break
            ;;
        *"FAILED"* | *"CREATE_COMPLETE"*)
            if [ "$1" = "delete" ]; then
                sceptre --no-colour delete -y $2 $3
            fi
            break
            ;;
        esac
    done
}

#reads sceptre output into a string, this is required as bit bucket doesnt accept multiline comment
format_change_output () {
    # if [ "$repo_type" = "bitbucket" ]; then
        stack_changes=""
        if [ "${trace-}" = "true" ]; then 
            set +x
        fi
        while read -r LINE
        do
        #temp fix to escape special char's handle it in a  better way later
        # LINE=$(sed -E 's/\//\\\//g' <<<"${LINE}") #escape /
        LINE=$(sed -E 's/\\/\\\\/g' <<<"${LINE}") #escape \ 
        if [ "$repo_type" = "bitbucket" ] || [ "$repo_type" = "github" ] ; then
            stack_changes="${stack_changes} $nl_sep ${LINE//\"/\\\"}" #add esc char for " and append to string
        else
            stack_changes="${stack_changes} $nl_sep ${LINE}"
        fi
        done < $1
        if [ "${trace-}" = "true" ]; then 
            set -x
        fi
        echo $stack_changes
    # fi
}

#check if the file really modified; ignore file if it contains only comments
check_if_file_changed() {
    file_name=$3
    file_name=`echo ${file_name#?} | sed -e 's/^[[:space:]]*//'` #remove A/M/D and trim the file name
    git diff --ignore-space-at-eol -b -w --ignore-blank-lines "$1:$file_name" "$2:$file_name" > changes.txt
    while read -r line ; do
        line=`echo ${line#?} | sed -e 's/^[[:space:]]*//'` #remove +/- and trim the line changed
        if [ -z "$line" ];then
            change_state=false
        elif [[ $line = \#* ]];then
            change_state=false
        else
            change_state=true
            break
        fi
    done <<<$(grep -e '^+ ' -e '^- ' changes.txt)
}

stack_status_report() {
    #labels
    dependency_label="Dependency cycle detected while running 'sceptre status' command, review the error below: "
    syntax_err_label="Syntax errors identified while running 'sceptre status' command, review the log below: "
    if [[ -z "${ignore_stacks}" ]]; then
        ignore_stacks=""
    fi
    switch_set_e
    sceptre status $env &> stack_status_report
    # sceptre status $env &> stack_status_report
    switch_set_e
    if grep "Dependency cycle detected" stack_status_report ; then
        echo $dependency_label > output
        cat stack_status_report >> output
        exit_and_set_build_status
    elif grep "Traceback " stack_status_report ; then
        echo $syntax_err_label > output
        echo "" >> output
        cat stack_status_report >> output
        exit_and_set_build_status
    elif grep "An error occurred" stack_status_report ; then
        echo $syntax_err_label > output
        echo "" >> output
        cat stack_status_report >> output
        exit_and_set_build_status
    elif grep "'dict object' has no attribute" stack_status_report ; then
        echo $syntax_err_label > output
        echo "" >> output
        cat stack_status_report >> output
        exit_and_set_build_status
    fi
    sed -i.bak '/Request limit exceeded/d' stack_status_report && rm -f stack_status_report.bak
    cat stack_status_report
}

#post comment to PR
post_pr_comment() {
    curl -s -X POST --header "PRIVATE-TOKEN: $GITLAB_SVC_ACCOUNT_TOKEN" -d "body=${1}" $api_url
}

#decline PR 
decline_pr() {
    curl --silent -u $bb_app_user:$bb_app_pwd $api_url/$repo_path/pullrequests/$1/decline \
        --request POST > /dev/null
}

# get no.of stacks changed in the current PR
get_new_stack_count() {
    new_stack_count=`git diff --name-status "$1" "$2" '*.yaml' | grep /config/ | wc -l`
}

switch_set_e() {
set_state=$-
if [[ $set_state =~ e ]]; then 
    set +e
else 
    set -e
fi
}

exit_and_set_build_status() {
    # export CODEBUILD_BUILD_SUCCEEDING=false
    echo "CODEBUILD_BUILD_SUCCEEDING=false" >> variables_file
    exit 0
}

get_pr_details() {

        if [ "$pr_status" == "OPEN" ]; then 
            pr_id=`git ls-remote ${CI_REPOSITORY_URL} refs/merge-requests/[0-9]*/head | awk "/$CI_COMMIT_SHA/"'{print $2}' | cut -d '/' -f3`
        elif [ "$pr_status" == "MERGED" ]; then 
            pr_id=`echo $CI_COMMIT_MESSAGE | grep "See merge request" | cut -d "!" -f2-`
        fi
        api_url="https://gitlab.com/api/v4/projects/$CI_PROJECT_ID/merge_requests/$pr_id/notes"
        # pr_status=`curl --silent -u $bb_app_user:$bb_app_pwd $api_url/$repo_path/pullrequests/$pr_id \
        #     | jq -r '.state'`
        # head_branch=`git name-rev --name-only $CODEBUILD_RESOLVED_SOURCE_VERSION`
}

# configure aws environment
# arg: "caller" - switch aws env to caller account where the pipeline is configured 
# No arg - then if $env exist configure the next env from deploy_environments else set the matching env for deploy_environment which is defined as codepipeline env variable
configure_aws_environment() {
   
    # account where the build is configured
    if [ -z "$caller_account" ];then
        # export ORIG_ACCOUNT=$caller_account
        caller_account=`aws sts get-caller-identity | jq -r .Account`
        aws sts assume-role --role-arn arn:aws:iam::$caller_account:role/cloudfoundation-admin --role-session-name cloufoundationAdmin > sts_caller.json
        export_aws_var sts_caller.json
    fi

    # if fun() arg is "caller" switch to original account/caller where the pipeline is configured 
    if [ "$1" == "caller" ];then
        export_aws_var sts_caller.json
        return
    elif [ "$1" == "env" ];then
        if [[ -z "$env" ]]; then
            export prev_env=$env_name
        else
            export prev_env=$env
        fi
        export env=$env_name
        aws sts assume-role --role-arn arn:aws:iam::$account_id:role/cloudfoundation-admin --role-session-name cloufoundationAdmin > sts.json
        export_aws_var sts.json
        env_detail="Environment name: $env_name | Account-Id: $account_id"
        env_separator="============================ENVIRONMENT:$env_name============================"
        return
    fi

    if [ -z "$env" ];then
        while read -r environment
        do  
            env_name=$(jq -r '.name' <<< "$environment")
            account_id=$(jq -r '.account_id' <<< "$environment")
            # region=$(jq -r '.region' <<< "$environment")
            
            # deploy_environment is set in codepipeline, basically this condition is check if build triggered by webhook OR pipeline
            # if deploy_environment is not set the build is triggered by webhooks 
            if [[ -z "${deploy_environment}" ]]; then
                break
            elif [ "$deploy_environment" == "$env_name" ]; then
            # this means we are at the right environment entry, no need to continue
                break
            fi
        done < deploy_environments
        # deploy_environments is a file generated by parser with all environments defined by cust in deployment descriptor

    else
        current_env=false
        next_env=false
        while read -r environment
        do
        env_name=$(jq -r '.name' <<< "$environment")
        account_id=$(jq -r '.account_id' <<< "$environment")
        
        if [ "$current_env" = true ];then
            next_env=true
            break
        fi
        if [ "$env_name" == "$env" ]; then
            current_env=true
        fi
        done < deploy_environments
    fi

    if [[ -z "$env" ]]; then
        export prev_env=$env_name
    else
    export prev_env=$env
    fi
    export env=$env_name
    #check if caller is same as deploy_env else use assume role.
    if [ "$account_id" != "$caller_account" ]; then
        aws sts assume-role --role-arn arn:aws:iam::$account_id:role/cloudfoundation-admin --role-session-name cloufoundationAdmin > sts.json
        export_aws_var sts.json
    fi
    env_detail="Environment name: $env_name | Account-Id: $account_id"
    env_separator="============================ENVIRONMENT:$env_name============================"
}

export_aws_var () {
    sts_file=$1
    if [ "${trace-}" = "true" ]; then 
        set +x
    fi
    export AWS_ACCESS_KEY_ID=`jq -r .Credentials.AccessKeyId $sts_file`
    export AWS_SECRET_ACCESS_KEY=`jq -r .Credentials.SecretAccessKey $sts_file`
    export AWS_SESSION_TOKEN=`jq -r .Credentials.SessionToken $sts_file`
    if [ "${trace-}" = "true" ]; then 
        set -x
    fi
}

process_plan_comments () {
    if [ "$env_count" -gt 1 ]; then
        post_pr_comment "$prefix $nl_sep $multi_env_label $nl_sep $note_summary $nl_sep  $nl_sep $env_separator $nl_sep $env_detail $nl_sep $plan_comment $more_details"
    else
        post_pr_comment "$prefix $nl_sep  $nl_sep $env_separator $nl_sep $env_detail $nl_sep $plan_comment $more_details"
    fi
}

process_plan () {
if [ -z "$plan_all" ] ; then
    plan_all=false
fi
if [ "$plan_all" = false ] || [ "$env_count" -lt 2 ] ; then
    cfci_plan
    note_summary="$note_summary $nl_sep 1) DEPLOY PLAN for environment: $env"
    process_plan_comments
elif [ "$plan_all" = true ]; then
    index=0
    while read -r environment
    do  
        env_name=$(jq -r '.name' <<< "$environment")
        account_id=$(jq -r '.account_id' <<< "$environment")
        configure_aws_environment "env"
        if [ "$index" -gt 0 ]; then
            stack_status_report
            validate_deployment_descriptor
        fi
        cfci_plan
        plan_comments="$plan_comments$env_separator $nl_sep $env_detail $nl_sep $plan_comment $nl_sep  $nl_sep "
        let index+=1
        configure_aws_environment "caller"
        note_summary="$note_summary $nl_sep $index) DEPLOY PLAN for environment: $env_name"
    done < deploy_environments
    post_pr_comment "$prefix $nl_sep $multi_env_label $nl_sep $plan_all_note $nl_sep $note_summary $nl_sep  $nl_sep $plan_comments $nl_sep  $nl_sep $more_details"
fi
}
#main starts here
# after script runs in seperate context, so load variables from before and script sections
if [ "$stage" = "post_build" ]; then
    source variables_file
fi

if [[ -z "${quickstart}" ]]; then
    quickstart="false"
fi

if [ "$quickstart" = true ]; then
    artifactory_base_url=https://repository.phdata.io/artifactory/cf-demo-templates/
fi

if [ "$stage" = "build" ]; then
    echo "CODEBUILD_BUILD_SUCCEEDING=true" >> variables_file
    #check for deployment descriptor file OR set default file name
    if [[ -z "${deployment_decriptor}" ]]; then
        deployment_decriptor="deployment.yaml"
    fi
    # parse deployment Descriptor
    python stack_parser.py $CI_PROJECT_DIR/$deployment_decriptor | tee parse_log
    env_count=`wc -l < deploy_environments`

    # configure aws environment
    configure_aws_environment

    # get stack status and validate deployment descriptor
    stack_status_report
    validate_deployment_descriptor 

    previous_env_detail=$env_detail
    previous_env_separator="============================ENVIRONMENT:$env============================"
    env_detail="Environment name: $env_name | Account-Id: $account_id"
    get_pr_details

    if [ "$pr_status" == "MERGED" ]; then
        cfci_deploy
        
        # Switch to caller account
        configure_aws_environment "caller"

        # configure aws environment for next environment defined in deploy_environments
        configure_aws_environment
        if [ "$next_env" = true ]; then
            echo "" >> stack_log
            echo "" >> stack_log
            
            # echo $env_separator >> stack_log
            # echo "" >> stack_log
            stack_status_report
            validate_deployment_descriptor
            cfci_plan
            format_change_output stack_log
            note_summary="$note_summary  $nl_sep 1) DEPLOY SUMMARY for environment: $prev_env  $nl_sep 2) DEPLOY PLAN for environment: $env "
            post_pr_comment "$prefix $nl_sep $multi_env_label $nl_sep $note_summary $nl_sep  $nl_sep $previous_env_separator $nl_sep $previous_env_detail $nl_sep $deploy_comment  $nl_sep $stack_changes $nl_sep   $nl_sep $env_separator $nl_sep $env_detail $nl_sep $plan_comment $nl_sep $nl_sep $more_details_with_appr"
        else
            format_change_output stack_log
            note_summary="$note_summary  $nl_sep 1) DEPLOY SUMMARY for environment: $env"
            post_pr_comment "$prefix $nl_sep $env_detail $nl_sep $note_summary $nl_sep $deploy_comment $nl_sep $stack_changes $nl_sep $more_details"
        fi
    elif [ "$pr_status" == "OPEN" ]; then    
        process_plan

    else
        echo "Action not defined"
    fi
elif [ "$stage" = "post_build" ] && [ "$CODEBUILD_BUILD_SUCCEEDING" = "false" ] ; then
    printenv
    format_change_output output
    cat output
    post_pr_comment "$prefix$build_failed$stack_changes$more_details"
    exit 1
fi
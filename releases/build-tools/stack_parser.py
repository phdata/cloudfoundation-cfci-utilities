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

# About the script

# a parser script uysed to parse cloudfoundation deployment descriptor 
#!/usr/bin/env python3
import json
import os
import sys
import yaml


# writes stacks to a file operation wise
def write_stacks(stacks, operation):
    with open(operation, 'w') as file:
        for stack in stacks:
            print(stack)
            if stack is not None:
                file.write("%s\n" % json.dumps(stack))
        file.close()
        if os.path.getsize(operation) == 0:
            os.remove(operation)


# parses deployment descriptor
def parse(descriptor, operations):
    others = []
    with open(descriptor, 'r') as stream:
        try:
            data = yaml.safe_load(stream)
            for element in data:
                if element in operations:
                    stacks = data[element]
                    if stacks is not None:
                            write_stacks(stacks, element)
                else:
                    others.append(element + "=" + str(data[element]))
                # write other elements into others
            if len(others) > 0:
                write_stacks(others, "deploy_properties")
        except yaml.YAMLError as exception:
            print(exception)


# variables
deploy_operations = ["deploy", "undeploy", "ignore", "deploy_environments"]
try:
    cf_descriptor = sys.argv[1]
except:
    print("Deployment descriptor must be passed as an argument for this utility")
    sys.exit(2)

# main
parse(cf_descriptor, deploy_operations)

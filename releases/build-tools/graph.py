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
# script to identify dependencies between different cloudformation stacks
#accepts two 3 parameters and gets the dependent stack list for a stack
# python script <project-name> <env> <env/stackname-without-env-and-without-extenstion>
# eg: python graph.py valhalla prod prod/instance1

from sceptre.context import SceptreContext
from sceptre.config.graph import StackGraph
from sceptre.config.reader import ConfigReader
import sys
import os

def get_dep(response, stack_name):
    for el in response:
        stack=el[0]
        if(stack.name == stack_name ):
            if len(stack.dependencies) > 0:
                for depstack in stack.dependencies:
                    if depstack.name in stack_list:
                        stack_list.remove(depstack.name )
                    stack_list.insert(0,depstack.name)
                    get_dep(response, depstack.name)

env = sys.argv[2]
context = SceptreContext(sys.argv[1], sys.argv[2], ignore_dependencies=False)
config_reader = ConfigReader(context)
all_stacks, command_stacks = config_reader.construct_stacks()
graph = StackGraph(all_stacks)
stack_list=[]
response= graph.count_dependencies(all_stacks)
get_dep(response,sys.argv[3])
# stack_list.append(sys.argv[3])

if os.path.exists("stack_graph"):
      os.remove("stack_graph")
      
with open('stack_graph', 'w') as f:
    for item in stack_list:
        stack=item.replace(env+"/", "") + ".yaml"
        f.write("%s\n" % stack)

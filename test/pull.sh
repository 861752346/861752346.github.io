#!/bin/bash

# 定义函数来显示帮助文档
display_help() {
    cat <<EOF
Usage: $0 [-h] [-s ARG] [-t ARG] [-p]

Options:
  -h 显示帮助.
  -s 设置原始镜像tag.
  -t 设置目标镜像tag，不传则不修改镜像tag.
  -p 保留本地镜像.
EOF
    exit 0
}

# 定义变量来存储参数值
option_s=
option_t=
option_p=

# 解析参数
while getopts ":hs:pt:" opt; do
  case $opt in
    h)
      display_help
      ;;
    s)
      # shellcheck disable=SC2034
      option_s=$OPTARG
      ;;
    t)
      # shellcheck disable=SC2034
      option_t=$OPTARG
      ;;
    p)
      # shellcheck disable=SC2034
      option_p="true"
      ;;
    \?)
      # 如果遇到无效的选项，显示帮助文档并退出
      echo "Invalid option: -$OPTARG" >&2
      display_help
      ;;
    :)
      # 如果选项需要一个参数但没有提供，显示帮助文档并退出
      echo "Option -$OPTARG requires an argument." >&2
      display_help
      ;;
  esac
done

# 检查是否提供了必要的参数
if [ -z "$option_s" ]; then
    echo "Error: -s are required."
    display_help
fi

# 如果目标tag为空，设置目标tag与源tag一致
if [ -z "$option_t" ]; then
    option_t="${option_s}"
fi

# 获取脚本目录
script_dir=$(dirname "$(readlink -f "$0")")
# 原始镜像tag
image_tag="${option_s}"
# 目标镜像tag
target_tag="${option_t}"

echo "执行docker manifest inspect 读取原始镜像platform信息"
# 执行docker manifest inspect命令并获取结果
result=$(docker manifest inspect "${image_tag}")
echo "原始镜像platform信息读取成功: ${result}"

# 解析json数据中的os和architecture属性
declare -a platform_list=()

# 使用jq工具解析manifest inspect结果，获取多架构平台信息
for row in $(echo "${result}" | jq -c '.manifests[]'); do
  os=$(echo "${row}" | jq -r '.platform.os')
  architecture=$(echo "${row}" | jq -r '.platform.architecture')
  if [[ "${architecture}" == "unknown" ]]; then
      echo "架构为unknown，跳过"
      continue
  fi
  platform_list+=("${os}/${architecture}")
done
echo "平台解析结果：${platform_list[*]}"

## 定义数组，用于存储最终推送到新的harbor的命令
declare -a command_list=()
command_list+=("#!/bin/bash")
command_list+=("set -x")
command_list+=("script_dir=\$(dirname \"\$(readlink -f \"\$0\")\")")

# 定义数组，用于存储多架构平台各镜像的临时tag名称
declare -a target_image_tag_list=()

# 遍历所有平台与架构，并逐一拉取镜像后保存为文件
for platform_info in "${platform_list[@]}"; do
  echo "遍历, platform_info:${platform_info} ,${platform_info//\//-}"
  set -x
  # 删除镜像，已经存在导致最终实际镜像与platform不符
  docker rmi "${image_tag}"
  # 拉取镜像
  docker pull --platform "${platform_info}" "${image_tag}"
  # 重命名镜像
  docker tag "${image_tag}" "${target_tag}.${platform_info//\//-}"
  # 保存镜像为本地文件
  docker save -o  "${script_dir}/image.${platform_info//\//-}.tar.gz" "${target_tag}.${platform_info//\//-}"
  if [ "${option_p}" != "true" ]; then
      docker rmi "${target_tag}.${platform_info//\//-}"
      docker rmi "${image_tag}"
  fi
  # 生成加载镜像命令
  command_list+=("docker load -i \${script_dir}/image.${platform_info//\//-}.tar.gz")
  # 生成推送镜像命令
  command_list+=("docker push ${target_tag}.${platform_info//\//-}")
  if [[ "${option_p}" != "true" ]]; then
      command_list+=("docker rmi ${target_tag}.${platform_info//\//-}")
  fi
  target_image_tag_list+=("${target_tag}.${platform_info//\//-}")
  set +x
done

# 生成创建清单命令
command_list+=("docker manifest create --amend --insecure ${target_tag} ${target_image_tag_list[*]}")
# 遍历所有平台与架构，并逐一拉取镜像后保存为文件
for platform_info in "${platform_list[@]}"; do
  IFS='/' read -ra parts <<< "${platform_info}"
   ## 生成标注清单命令
  command_list+=("docker manifest annotate ${target_tag} ${target_tag}.${platform_info//\//-} --os ${parts[0]} --arch ${parts[1]}")
done

# 生成推送清单命令
command_list+=("docker manifest push --purge --insecure ${target_tag}")
command_list+=("set -x")

command_str=""
for command in "${command_list[@]}"; do
  command_str="${command_str}\n${command}"
done

set -x
echo -e "${command_str}" > "${script_dir}"/image.push.sh

chmod +x image.push.sh

# 压缩结果
find "${script_dir}" -name "image.*" -printf '%f\0' | tar -czvf "${script_dir}/result.tar.gz" --null -T -
find "${script_dir}" -name "image.*" -exec rm -rf {} \;
set +x
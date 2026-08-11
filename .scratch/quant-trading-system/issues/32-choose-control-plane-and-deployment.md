# 选择控制面实现与部署机制

Type: grilling
Status: closed
Resolution: out-of-scope
Blocked by: 31
Parent: [设计生产级多策略低延迟加密量化交易系统](../map.md)

## Question

基于控制面技术研究，首版应采用什么后端、持久状态、命令分发、节点代理和 systemd 发布组合，如何划分模块接口，并明确哪些高可用或编排能力暂不建设？

## Answer

当前原型不选择控制面后端、节点代理或部署机制；业务层只保留已经定义的命令、状态与幂等契约。

## Comments

- 2026-07-29：随原型范围收敛移出本地图。

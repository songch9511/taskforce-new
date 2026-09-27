"use client";

import { useState } from "react";

import { Button } from "@/components/ui/button";
import type { DataSourceSetting, DataSourceSummary, TaskPropertyMap } from "@/lib/api/contract";

// Notion 데이터베이스마다 역할(할 일 · 회의 · 무시)과 속성 매핑을 확인한다. 확인한 할 일 DB만 동기화에서 구조화된 할 일로 처리한다.

const ROLE_LABELS: Record<DataSourceSetting["role"], string> = { tasks: "할 일 DB (속성으로)", text: "글 원문으로 (회의록 · 문서)", ignore: "가져오지 않음" };
const STATUS_LABELS = { open: "진행 중 (open)", done: "완료 (done)", dropped: "취소 (dropped)" } as const;
type TaskStatus = keyof typeof STATUS_LABELS;

const selectClass = "border-input bg-background rounded-md border px-2 py-1 text-sm";

export function DataSourcesPanel({ connectionId }: { connectionId: string }) {
  const [items, setItems] = useState<DataSourceSummary[] | null>(null);
  const [loading, setLoading] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  async function load() {
    setLoading(true);
    setMessage(null);
    try {
      const response = await fetch(`/api/v1/connections/${connectionId}/data-sources`);
      const body = (await response.json()) as { dataSources?: DataSourceSummary[]; error?: { message: string } };
      if (!response.ok) setMessage(body.error?.message ?? `불러오지 못했습니다 (${response.status})`);
      else setItems(body.dataSources ?? []);
    } catch {
      setMessage("서버에 연결하지 못했습니다.");
    } finally {
      setLoading(false);
    }
  }

  if (!items) {
    return (
      <div className="flex items-center gap-3">
        <Button variant="outline" size="sm" onClick={load} disabled={loading}>
          {loading ? "불러오는 중…" : "데이터베이스 역할 설정"}
        </Button>
        {message && <span className="text-destructive text-sm">{message}</span>}
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-3">
      <p className="text-muted-foreground text-sm">
        할 일 DB로 확인한 데이터베이스는 담당 · 기한 · 상태 속성을 그대로 Action에 반영합니다 (LLM을 쓰지 않음). &quot;가져오지 않음&quot;으로 확인한
        데이터베이스는 건너뜁니다. 확인하기 전에는 글 원문으로 읽습니다. 목표 · 투표처럼 약속이 나오지 않는 데이터베이스는 &quot;가져오지 않음&quot;으로 두면
        LLM으로 읽지 않습니다.
      </p>
      {items.length === 0 && <p className="text-muted-foreground text-sm">연결에 공유된 데이터베이스가 없습니다.</p>}
      {items.map((item) => (
        <DataSourceRow
          key={item.id}
          connectionId={connectionId}
          item={item}
          onSaved={(saved) => setItems((list) => list?.map((x) => (x.id === saved.id ? saved : x)) ?? null)}
        />
      ))}
    </div>
  );
}

function DataSourceRow({ connectionId, item, onSaved }: { connectionId: string; item: DataSourceSummary; onSaved: (saved: DataSourceSummary) => void }) {
  const [role, setRole] = useState(item.setting.role);
  const [props, setProps] = useState<TaskPropertyMap | undefined>(item.setting.props);
  const [statusMap, setStatusMap] = useState<Record<string, TaskStatus>>(item.setting.statusMap ?? {});
  const [pending, setPending] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  const ofType = (...types: string[]) => item.properties.filter((p) => types.includes(p.type));
  const statusOptions =
    props?.status.type === "checkbox"
      ? [
          { id: "true", name: "체크됨", group: null },
          { id: "false", name: "체크 안 됨", group: null },
        ]
      : item.statusOptions.filter((o) => o.propertyId === props?.status.id);

  // 제안에서 할 일 DB가 아니었던 데이터베이스도 고를 수 있게, 타입이 맞는 첫 속성으로 매핑을 채운다.
  function chooseRole(next: DataSourceSetting["role"]) {
    setRole(next);
    if (next !== "tasks" || props) return;
    const [title] = ofType("title");
    const [assignee] = ofType("people");
    const [status] = ofType("status", "checkbox");
    const [due] = ofType("date");
    if (title && assignee && status) {
      setProps({ title: title.id, assignee: assignee.id, due: due?.id ?? null, status: { id: status.id, type: status.type as "status" | "checkbox" } });
    }
  }
  const canBeTasks = Boolean(props) || (ofType("title").length > 0 && ofType("people").length > 0 && ofType("status", "checkbox").length > 0);

  async function save() {
    setPending(true);
    setMessage(null);
    try {
      const response = await fetch(`/api/v1/connections/${connectionId}/data-sources/${item.id}`, {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ role, ...(role === "tasks" ? { props, statusMap } : {}) }),
      });
      const body = (await response.json()) as { dataSource?: DataSourceSummary; error?: { message: string } };
      if (!response.ok || !body.dataSource) {
        setMessage(body.error?.message ?? `저장하지 못했습니다 (${response.status})`);
        return;
      }
      onSaved(body.dataSource);
      setStatusMap(body.dataSource.setting.statusMap ?? {});
      setMessage(role === "tasks" ? "확인했습니다. 다음 동기화에서 열린 할 일을 가져옵니다." : "확인했습니다.");
    } catch {
      setMessage("서버에 연결하지 못했습니다.");
    } finally {
      setPending(false);
    }
  }

  const propSelect = (label: string, value: string | null, types: string[], onChange: (id: string | null) => void, optional = false) => (
    <label className="flex items-center gap-2 text-sm">
      <span className="text-muted-foreground w-10">{label}</span>
      <select className={selectClass} value={value ?? ""} onChange={(e) => onChange(e.target.value || null)}>
        {optional && <option value="">없음</option>}
        {ofType(...types).map((p) => (
          <option key={p.id} value={p.id}>
            {p.name}
          </option>
        ))}
      </select>
    </label>
  );

  return (
    <div className="flex flex-col gap-2 rounded-md border px-3 py-2">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="text-sm">
          <span className="font-medium">{item.title ?? "(제목 없음)"}</span>
          <span className="text-muted-foreground"> · {item.confirmed ? "확인됨" : "제안 (확인 전에는 글 원문으로 읽음)"}</span>
          {!item.reachable && (
            <div className="text-destructive">
              읽을 수 없습니다. 위의 &quot;Notion 다시 연결 · 페이지 추가&quot;에서 이 데이터베이스(팀스페이스 맨 위에 있으면 데이터베이스 자체)나 이
              데이터베이스가 들어 있는 상위 페이지를 고르거나, 필요 없으면 &quot;가져오지 않음&quot;으로 바꿔 주세요.
            </div>
          )}
        </div>
        <div className="flex items-center gap-2">
          <select className={selectClass} value={role} onChange={(e) => chooseRole(e.target.value as DataSourceSetting["role"])}>
            {(Object.keys(ROLE_LABELS) as DataSourceSetting["role"][]).map((r) => (
              <option key={r} value={r} disabled={r === "tasks" && (!canBeTasks || !item.reachable)}>
                {ROLE_LABELS[r]}
              </option>
            ))}
          </select>
          <Button size="sm" onClick={save} disabled={pending || (role === "tasks" && (!props || !item.reachable))}>
            {pending ? "저장 중…" : "확인"}
          </Button>
        </div>
      </div>

      {role === "tasks" && props && item.reachable && (
        <div className="flex flex-col gap-2">
          <div className="flex flex-wrap gap-4">
            {propSelect("제목", props.title, ["title"], (id) => id && setProps({ ...props, title: id }))}
            {propSelect("담당", props.assignee, ["people"], (id) => id && setProps({ ...props, assignee: id }))}
            {propSelect("기한", props.due, ["date"], (id) => setProps({ ...props, due: id }), true)}
            {propSelect("상태", props.status.id, ["status", "checkbox"], (id) => {
              const type = item.properties.find((p) => p.id === id)?.type;
              if (id && (type === "status" || type === "checkbox")) {
                setProps({ ...props, status: { id, type } });
                setStatusMap({});
              }
            })}
          </div>
          <table className="text-sm">
            <tbody>
              {statusOptions.map((option) => (
                <tr key={option.id}>
                  <td className="text-muted-foreground py-1 pr-3">
                    {option.name}
                    {option.group && <span> · {option.group}</span>}
                  </td>
                  <td className="py-1">
                    <select
                      className={selectClass}
                      value={statusMap[option.id] ?? ""}
                      onChange={(e) => {
                        const rest = Object.fromEntries(Object.entries(statusMap).filter(([key]) => key !== option.id));
                        setStatusMap(e.target.value ? { ...rest, [option.id]: e.target.value as TaskStatus } : rest);
                      }}
                    >
                      <option value="">기본값</option>
                      {(Object.keys(STATUS_LABELS) as TaskStatus[]).map((s) => (
                        <option key={s} value={s}>
                          {STATUS_LABELS[s]}
                        </option>
                      ))}
                    </select>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {message && <p className="text-muted-foreground text-sm">{message}</p>}
    </div>
  );
}

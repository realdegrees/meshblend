using UnityEditor;
using UnityEngine;

namespace MeshBlending.Editor
{
    /// <summary>
    /// The feature's inspector: its fields as usual, then the surface groups' blend matrix, one toggle per pair of
    /// groups, like the physics layer collision matrix.
    /// </summary>
    [CustomEditor(typeof(MeshBlendRendererFeature))]
    sealed class MeshBlendRendererFeatureEditor : UnityEditor.Editor
    {
        const float Cell = 18f;
        const float LabelWidth = 130f;

        public override void OnInspectorGUI()
        {
            serializedObject.Update();
            DrawDefaultInspector();

            SerializedProperty groups = serializedObject.FindProperty("groups");
            int count = Mathf.Min(groups.arraySize, MeshBlendRendererFeature.MaxGroups);
            if (groups.arraySize > MeshBlendRendererFeature.MaxGroups)
                EditorGUILayout.HelpBox($"Only the first {MeshBlendRendererFeature.MaxGroups} groups are used.",
                    MessageType.Warning);
            if (count == 0) return;

            EditorGUILayout.Space();
            EditorGUILayout.LabelField("Blend Matrix", EditorStyles.boldLabel);
            EditorGUILayout.LabelField("Which groups blend with each other where they meet.", EditorStyles.miniLabel);

            var names = new string[count];
            for (int i = 0; i < count; i++)
            {
                string name = groups.GetArrayElementAtIndex(i).FindPropertyRelative("name").stringValue;
                names[i] = string.IsNullOrEmpty(name) ? $"Group {i}" : name;
            }

            // Column headers, written downward so long names fit, then one row per group with a toggle for every group
            // from the last down to itself.
            float headerHeight = 0f;
            foreach (string name in names)
                headerHeight = Mathf.Max(headerHeight, EditorStyles.miniLabel.CalcSize(new GUIContent(name)).x + 6f);
            Rect header = GUILayoutUtility.GetRect(LabelWidth + count * Cell, headerHeight);
            for (int column = 0; column < count; column++)
            {
                int group = count - 1 - column;
                var pivot = new Vector2(header.x + LabelWidth + column * Cell + Cell * 0.5f + 7f, header.yMax);
                Matrix4x4 saved = GUI.matrix;
                GUIUtility.RotateAroundPivot(-90f, pivot);
                GUI.Label(new Rect(pivot.x, pivot.y - 16f, headerHeight, 16f), names[group], EditorStyles.miniLabel);
                GUI.matrix = saved;
            }

            for (int row = 0; row < count; row++)
            {
                Rect line = GUILayoutUtility.GetRect(LabelWidth + count * Cell, Cell);
                GUI.Label(new Rect(line.x, line.y, LabelWidth, Cell), names[row], EditorStyles.miniLabel);
                for (int column = 0; column < count - row; column++)
                {
                    int other = count - 1 - column;
                    SerializedProperty mine = groups.GetArrayElementAtIndex(row).FindPropertyRelative("blendsWith");
                    SerializedProperty theirs = groups.GetArrayElementAtIndex(other).FindPropertyRelative("blendsWith");
                    bool on = (mine.intValue & (1 << other)) != 0 && (theirs.intValue & (1 << row)) != 0;
                    var cell = new Rect(line.x + LabelWidth + column * Cell, line.y, Cell, Cell);
                    bool next = EditorGUI.Toggle(cell, GUIContent.none, on);
                    if (next == on) continue;
                    mine.intValue = next ? mine.intValue | (1 << other) : mine.intValue & ~(1 << other);
                    theirs.intValue = next ? theirs.intValue | (1 << row) : theirs.intValue & ~(1 << row);
                }
            }

            serializedObject.ApplyModifiedProperties();
        }
    }
}
